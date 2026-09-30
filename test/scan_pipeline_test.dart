import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:medisense/services/medicine_label_parser.dart';
import 'package:medisense/services/scan_pipeline.dart';

void main() {
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
