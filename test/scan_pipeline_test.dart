import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:medisense/services/medicine_label_parser.dart';
import 'package:medisense/services/medicine_expiry_parser.dart';
import 'package:medisense/services/ocr_capture_stability_gate.dart';
import 'package:medisense/services/ph_drug_catalog.dart';
import 'package:medisense/services/scan_pipeline.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'broken OCR name stays provisional until an exact package read',
    () async {
      await PhDrugCatalog.instance.ensureLoaded();
      final catalog = PhDrugCatalog.instance;
      expect(
        catalog.findTentativeGeneric('Para mol ta')?.canonicalName,
        'Paracetamol',
      );
      expect(catalog.findTentativeGeneric('Para mol ta')?.exact, isFalse);
      expect(catalog.findTentativeGeneric('caps mineral'), isNull);

      final parser = MedicineLabelParser();
      expect(parser.previewMedicineName('Para mol ta\n500 mg'), 'Paracetamol');
      final still = parser.parsePackage('Paracetamol\n500 mg\nEXP 12/2028');
      expect(still?.name, 'Paracetamol');
      expect(still?.dosage, '500 mg');

      final withOriginalText = await parser.resolveCatalogPackage(
        'Paracetamol\n500 mg\nEXP 12/2028',
        parser.parsePackage('Paracetamol\n500 mg'),
        lookup: (_) async => [],
      );
      expect(MedicineExpiryParser.parse(withOriginalText!.rawText), isNotNull);

      final preview = ScanPreviewEvidence();
      preview.observeNameHint('Paracetamol');
      preview.observeNameHint('Paracetamol');
      preview.observeStrengthHint('500 mg');
      preview.observeStrengthHint('500 mg');
      expect(preview.supportsTentativeNameAndStrength(still!), isTrue);
      final weakPreview = ScanPreviewEvidence();
      weakPreview.observeNameHint('Paracetamol');
      weakPreview.observeNameHint('Paracetamol');
      weakPreview.observeStrengthHint('500 mg');
      expect(weakPreview.supportsTentativeNameAndStrength(still), isFalse);
    },
  );

  test(
    'catalog name wins over corrupted package text and mixed strengths',
    () async {
      await PhDrugCatalog.instance.ensureLoaded();
      final parser = MedicineLabelParser();
      final label = parser.parsePackage(
        'Analmin\nMefenamicmic Acid Ci\n500 mg\nLOT 9182\nEXP 12/2028',
      );
      expect(label?.name.toLowerCase(), contains('analmin'));
      expect(label?.dosage, '500 mg');
      expect(label?.activeIngredients, contains('Mefenamic Acid'));
      final ambiguous = parser.parsePackage(
        'Paracetamol\n500 mg\n250 mg\nEXP 12/2028',
      );
      expect(ambiguous?.name, 'Paracetamol');
      expect(ambiguous?.dosage, isEmpty);
      expect(ambiguous?.strengthConflict, isTrue);
    },
  );

  test(
    'preview recognizes a unique medicine prefix without guessing dosage',
    () {
      final parser = MedicineLabelParser();
      expect(parser.previewMedicineName('A mefe'), 'Mefenamic Acid');
      expect(parser.previewMedicineName('caps mineral'), isNull);
    },
  );

  test(
    'capture gate progresses from partial name or dose to a complete read',
    () {
      OcrCaptureStabilityGate gate() =>
          OcrCaptureStabilityGate(minSharpness: 50, minTextCoverage: 0.03);
      bool observe(
        OcrCaptureStabilityGate gate,
        String text,
        int milliseconds, {
        String? medicineName,
      }) => gate.observe(
        text: text,
        medicineName: medicineName,
        at: Duration(milliseconds: milliseconds),
        coverage: 0.05,
        clippedAtEdge: false,
        sharpness: 120,
      );

      final fromName = gate();
      expect(
        observe(fromName, 'A mefe', 0, medicineName: 'Mefenamic Acid'),
        isFalse,
      );
      expect(
        observe(
          fromName,
          'Mefenamic Acid 500 mg',
          500,
          medicineName: 'Mefenamic Acid',
        ),
        isTrue,
      );

      final fromDose = gate();
      expect(observe(fromDose, '500 mg', 0), isFalse);
      expect(
        observe(
          fromDose,
          'Mefenamic Acid 500 mg',
          500,
          medicineName: 'Mefenamic Acid',
        ),
        isTrue,
      );

      final conflict = gate();
      expect(
        observe(
          conflict,
          'Mefenamic Acid 250 mg',
          0,
          medicineName: 'Mefenamic Acid',
        ),
        isFalse,
      );
      expect(
        observe(
          conflict,
          'Mefenamic Acid 500 mg',
          500,
          medicineName: 'Mefenamic Acid',
        ),
        isFalse,
      );
    },
  );
  group('MedicineCatalogRepository', () {
    const catalog = MedicineCatalogRepository(
      entries: [
        MedicineCatalogEntry(
          name: 'Paracetamol',
          dosage: '500 mg',
          aliases: ['Biogesic'],
          barcodes: ['4800012345678'],
        ),
      ],
    );

    test('matches a known barcode locally', () {
      final match = catalog.findByBarcode('4800012345678');
      expect(match?.entry.name, 'Paracetamol');
      expect(match?.confidence, 0.99);
    });

    test('does not invent a result for an unknown barcode', () {
      expect(catalog.findByBarcode('0000000000000'), isNull);
    });

    test('matches a local alias in OCR text', () {
      final match = catalog.findByText('Biogesic 500 mg tablet');
      expect(match?.entry.name, 'Paracetamol');
    });
  });

  test('ScanFrameGate suppresses repeated automatic text', () {
    final gate = ScanFrameGate();
    final first = DateTime(2026, 1, 1, 12);
    expect(gate.shouldProcess('Paracetamol 500 mg', first), isTrue);
    expect(
      gate.shouldProcess(
        ' paracetamol   500 mg ',
        first.add(const Duration(milliseconds: 500)),
      ),
      isFalse,
    );
    expect(
      gate.shouldProcess(
        'paracetamol 500 mg',
        first.add(const Duration(seconds: 3)),
      ),
      isTrue,
    );
  });

  test('automatic results need consecutive matching medicine reads', () {
    final gate = ScanResultStabilityGate();
    const paracetamol = MedicineLabelResult(
      name: 'Paracetamol',
      dosage: '500 mg',
      confidence: 0.9,
      nameConfidence: 0.9,
      dosageConfidence: 0.9,
      rawText: 'Paracetamol 500 mg',
    );
    const other = MedicineLabelResult(
      name: 'Ibuprofen',
      dosage: '200 mg',
      confidence: 0.9,
      nameConfidence: 0.9,
      dosageConfidence: 0.9,
      rawText: 'Ibuprofen 200 mg',
    );
    expect(gate.accept(paracetamol), isFalse);
    expect(gate.accept(other), isFalse);
    expect(gate.accept(paracetamol), isFalse);
    expect(gate.accept(paracetamol), isTrue);
    expect(gate.accept(null), isFalse);
    expect(gate.accept(paracetamol), isFalse);
  });

  test('canonical gate ignores OCR unit spacing and packaging noise', () {
    final gate = ScanResultStabilityGate();
    const first = MedicineLabelResult(
      name: 'MYREFEN',
      dosage: 'S00 Meg',
      confidence: .8,
      nameConfidence: .8,
      dosageConfidence: .8,
      rawText: 'MYREFEN S00 Meg NSAID',
    );
    const second = MedicineLabelResult(
      name: 'Myrefen',
      dosage: '500 mog',
      confidence: .8,
      nameConfidence: .8,
      dosageConfidence: .8,
      rawText: 'MYREFEN 500 mog BN: V780',
    );
    expect(gate.accept(first), isFalse);
    expect(gate.accept(second), isTrue);
  });

  test('rolling accumulator expires and rejects conflicting strengths', () {
    const result = MedicineLabelResult(
      name: 'Myrefen',
      dosage: '',
      confidence: .7,
      nameConfidence: .8,
      dosageConfidence: 0,
      rawText: 'Myrefen',
    );
    final at = DateTime(2026, 1, 1);
    final rolling = ScanRollingAccumulator();
    rolling.observe(text: '500 mg', at: at);
    expect(
      rolling.merge(result, at: at.add(const Duration(seconds: 1))).dosage,
      '500mg',
    );
    expect(
      rolling.merge(result, at: at.add(const Duration(seconds: 3))).dosage,
      isEmpty,
    );
    rolling.observe(text: '500 mg', at: at.add(const Duration(seconds: 4)));
    rolling.observe(text: '250 mg', at: at.add(const Duration(seconds: 5)));
    expect(
      rolling.merge(result, at: at.add(const Duration(seconds: 5))).dosage,
      isEmpty,
    );
  });

  test('a name-only still needs two complete canonical reads', () {
    final gate = ScanResultStabilityGate();
    const partial = MedicineLabelResult(
      name: 'Mefenamic Acid',
      dosage: '',
      confidence: 0.58,
      nameConfidence: 0.78,
      dosageConfidence: 0,
      rawText: 'Mefenamic Acid',
    );
    const complete = MedicineLabelResult(
      name: 'Mefenamic Acid',
      dosage: '500 mg',
      confidence: 0.82,
      nameConfidence: 0.84,
      dosageConfidence: 0.90,
      rawText: 'Mefenamic Acid 500 mg',
    );
    expect(gate.accept(partial), isFalse);
    expect(gate.accept(complete), isFalse);
    expect(gate.accept(complete), isTrue);
    gate.reset();
    expect(gate.accept(partial), isFalse);
    expect(
      gate.accept(
        const MedicineLabelResult(
          name: 'Ibuprofen',
          dosage: '500 mg',
          confidence: 0.82,
          nameConfidence: 0.84,
          dosageConfidence: 0.90,
          rawText: 'Ibuprofen 500 mg',
        ),
      ),
      isFalse,
    );
  });

  test(
    'a partial preview name and complete preview line support the still',
    () {
      final evidence = ScanPreviewEvidence();
      const item = PrescriptionItem(
        drugName: 'Mefenamic Acid',
        strength: '500 mg',
        quantity: '',
        frequency: '',
        rawLine: 'Mefenamic Acid 500 mg',
      );
      const result = MedicineLabelResult(
        name: 'Mefenamic Acid',
        dosage: '500 mg',
        confidence: 0.72,
        nameConfidence: 0.72,
        dosageConfidence: 0.85,
        rawText: 'Mefenamic Acid 500 mg',
      );
      evidence.observeNameHint('Mefenamic Acid');
      expect(evidence.supports(result), isFalse);
      evidence.observe([item]);
      expect(evidence.snapshotAndReset().supports(result), isTrue);
      evidence.observeNameHint('Mefenamic Acid');
      evidence.observe([item]);
      expect(
        evidence.snapshotAndReset().supports(
          const MedicineLabelResult(
            name: 'Mefenamic Acid',
            dosage: '250 mg',
            confidence: 0.72,
            nameConfidence: 0.72,
            dosageConfidence: 0.85,
            rawText: 'Mefenamic Acid 250 mg',
          ),
        ),
        isFalse,
      );
    },
  );

  test('a dosage-only preview can corroborate one complete medicine line', () {
    final evidence = ScanPreviewEvidence();
    const item = PrescriptionItem(
      drugName: 'Mefenamic Acid',
      strength: '500 mg',
      quantity: '',
      frequency: '',
      rawLine: 'Mefenamic Acid 500 mg',
    );
    const result = MedicineLabelResult(
      name: 'Mefenamic Acid',
      dosage: '500 mg',
      confidence: 0.72,
      nameConfidence: 0.72,
      dosageConfidence: 0.85,
      rawText: 'Mefenamic Acid 500 mg',
    );
    evidence.observeStrengthHint('500 mg');
    evidence.observe([item]);
    expect(evidence.snapshotAndReset().supports(result), isTrue);
    evidence.observeStrengthHint('250 mg');
    evidence.observe([item]);
    expect(evidence.snapshotAndReset().supports(result), isFalse);
  });

  test('preview strength disagreements survive until final review', () {
    final evidence = ScanPreviewEvidence();
    const fiveHundred = PrescriptionItem(
      drugName: 'Paracetamol',
      strength: '500 mg',
      quantity: '',
      frequency: '',
      rawLine: 'Paracetamol 500 mg',
    );
    const threeHundred = PrescriptionItem(
      drugName: 'Paracetamol',
      strength: '300 mg',
      quantity: '',
      frequency: '',
      rawLine: 'Paracetamol 300 mg',
    );
    const result = MedicineLabelResult(
      name: 'Paracetamol',
      dosage: '500 mg',
      confidence: 0.9,
      nameConfidence: 0.9,
      dosageConfidence: 0.9,
      rawText: 'Paracetamol 500 mg',
    );

    evidence.observe([fiveHundred]);
    evidence.observe([threeHundred]);
    expect(evidence.snapshotAndReset().conflictsWith(result), isTrue);
    evidence.observe([fiveHundred]);
    evidence.observe([fiveHundred]);
    expect(evidence.snapshotAndReset().conflictsWith(result), isFalse);
    evidence.observe([threeHundred]);
    evidence.observe([threeHundred]);
    expect(evidence.snapshotAndReset().conflictsWith(result), isTrue);
  });

  test('two agreeing preview frames support one matching still read', () {
    final evidence = ScanPreviewEvidence();
    const item = PrescriptionItem(
      drugName: 'Paracetamol',
      strength: '500 mg',
      quantity: '',
      frequency: '',
      rawLine: 'Paracetamol 500 mg',
    );
    const match = MedicineLabelResult(
      name: 'Paracetamol',
      dosage: '500 mg',
      confidence: 0.9,
      nameConfidence: 0.9,
      dosageConfidence: 0.9,
      rawText: 'Paracetamol 500 mg',
    );
    const differentDose = MedicineLabelResult(
      name: 'Paracetamol',
      dosage: '250 mg',
      confidence: 0.9,
      nameConfidence: 0.9,
      dosageConfidence: 0.9,
      rawText: 'Paracetamol 250 mg',
    );
    evidence.observe([item]);
    expect(evidence.supports(match), isFalse);
    evidence.observe([item]);
    expect(evidence.supports(match), isTrue);
    expect(evidence.supports(differentDose), isFalse);
  });

  test(
    'prescription batches need two matching reads independent of row order',
    () {
      final gate = ScanResultStabilityGate();
      const metformin = MedicineLabelResult(
        name: 'Metformin',
        dosage: '500 mg',
        confidence: 0.9,
        nameConfidence: 0.9,
        dosageConfidence: 0.9,
        rawText: 'Metformin 500 mg BID',
      );
      const amlodipine = MedicineLabelResult(
        name: 'Amlodipine',
        dosage: '5 mg',
        confidence: 0.9,
        nameConfidence: 0.9,
        dosageConfidence: 0.9,
        rawText: 'Amlodipine 5 mg daily',
      );

      expect(gate.acceptBatch([metformin, amlodipine]), isFalse);
      expect(gate.acceptBatch([amlodipine, metformin]), isTrue);
      expect(gate.acceptBatch([metformin]), isFalse);
      expect(gate.acceptBatch([metformin, amlodipine]), isFalse);
    },
  );

  test('barcode results carry their source', () {
    const result = MedicineLabelResult(
      name: 'Paracetamol',
      dosage: '500 mg',
      confidence: 0.99,
      nameConfidence: 0.99,
      dosageConfidence: 0.99,
      rawText: 'Barcode match',
      source: ScanSource.barcode,
    );
    expect(result.source, ScanSource.barcode);
  });

  test('worker prepares bounded ROI and releases derived images', () async {
    final directory = await Directory.systemTemp.createTemp('medisense_scan_');
    final source = File('${directory.path}/capture.jpg');
    final image = img.Image(2000, 1000);
    img.fill(image, img.getColor(255, 255, 255));
    await source.writeAsBytes(img.encodeJpg(image));
    final processor = ImagePreprocessor();
    try {
      final prepared = await processor.prepareForOcr(source.path);
      expect(prepared, isNotNull);
      expect(prepared, startsWith(Directory.systemTemp.path));
      final decoded = img.decodeImage(await File(prepared!).readAsBytes())!;
      expect(decoded.width, lessThanOrEqualTo(1280));
      expect(decoded.height, lessThanOrEqualTo(1280));
      expect(decoded.width, decoded.height);
      final fullPage = await processor.prepareForOcr(
        source.path,
        centerCrop: false,
      );
      expect(fullPage, isNotNull);
      final fullPageImage = img.decodeImage(
        await File(fullPage!).readAsBytes(),
      )!;
      expect(fullPageImage.width, 1280);
      expect(fullPageImage.height, 640);
      final enhanced = await processor.getEnhancedImage(prepared);
      expect(enhanced, isNotNull);
      await processor.release(prepared);
      await processor.release(source.path);
      expect(File(prepared).existsSync(), isFalse);
      expect(File(fullPage).existsSync(), isFalse);
      expect(File(enhanced!).existsSync(), isFalse);
    } finally {
      await processor.dispose();
      await directory.delete(recursive: true);
    }
  });

  test('derived file survives until native reader future settles', () async {
    final directory = await Directory.systemTemp.createTemp('medisense_lease_');
    final source = File('${directory.path}/capture.jpg');
    await source.writeAsBytes(img.encodeJpg(img.Image(100, 100)));
    final processor = ImagePreprocessor();
    try {
      final prepared = (await processor.prepareForOcr(source.path))!;
      final nativeDone = Completer<void>();
      final reading = processor.withNativeReader(
        prepared,
        () => nativeDone.future,
      );
      final deleting = processor.releaseGenerated(prepared);
      await Future<void>.delayed(Duration.zero);
      expect(File(prepared).existsSync(), isTrue);
      nativeDone.complete();
      await reading;
      await deleting;
      expect(File(prepared).existsSync(), isFalse);
    } finally {
      await processor.dispose();
      await directory.delete(recursive: true);
    }
  });

  test('worker crops the normalized viewfinder before OCR', () async {
    final directory = await Directory.systemTemp.createTemp('medisense_roi_');
    final source = File('${directory.path}/capture.jpg');
    final image = img.Image(400, 300);
    img.fill(image, img.getColor(220, 20, 20));
    img.fillRect(image, 100, 75, 299, 224, img.getColor(20, 180, 20));
    await source.writeAsBytes(img.encodeJpg(image));
    final processor = ImagePreprocessor();
    try {
      final roi = await processor.cropViewfinderRoi(
        source.path,
        const ScanRoi(0.25, 0.25, 0.5, 0.5),
      );
      expect(roi, isNotNull);
      final cropped = img.decodeImage(await File(roi!).readAsBytes())!;
      expect(cropped.width, 200);
      expect(cropped.height, 150);
      final middle = cropped.getPixel(100, 75);
      expect(img.getGreen(middle), greaterThan(img.getRed(middle)));
      await processor.release(source.path);
      expect(File(roi).existsSync(), isFalse);
    } finally {
      await processor.dispose();
      await directory.delete(recursive: true);
    }
  });
}
