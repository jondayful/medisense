import 'dart:math' as math;
import 'dart:ui';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../models/dosage.dart';
import '../data/database_helper.dart';
import 'ocr_text_cleanup.dart';
import 'ph_drug_catalog.dart';
import 'prescription_safety.dart';

/// Compact structured result for a single medicine label or prescription row.
/// Empty strength/frequency means OCR did not provide an explicit value.
/// [isHighConfidence] describes extraction confidence, never prescribing safety.
class ParsedMedicine {
  final String medicineName;
  final String strength;
  final String frequency;
  final double confidenceScore;
  final bool isHighConfidence;

  const ParsedMedicine({
    required this.medicineName,
    required this.strength,
    required this.frequency,
    required this.confidenceScore,
    required this.isHighConfidence,
  });
}

enum MedicineLabelKind { medicine, alcohol, perfume, unknown }

enum ScanSource { ocr, barcode, localMatch, aiCleanup }

/// A prescription row extracted without assuming that the drug exists in a
/// regional catalog. This is the lossless representation used for review and
/// for international prescriptions.
class PrescriptionItem {
  final String drugName;
  final String strength;
  final String quantity;
  final String frequency;
  final String rawLine;

  const PrescriptionItem({
    required this.drugName,
    required this.strength,
    required this.quantity,
    required this.frequency,
    required this.rawLine,
  });
}

/// Rule-based indication that OCR is looking at a prescription page. This is
/// a layout/content hint only; it does not verify a drug or validate a dose.
class PrescriptionDocumentDetection {
  final bool isPrescription;
  final double confidence;
  final List<PrescriptionItem> items;

  const PrescriptionDocumentDetection({
    required this.isPrescription,
    required this.confidence,
    required this.items,
  });
}

class MedicineLabelClassification {
  final MedicineLabelKind kind;
  final double confidence;

  const MedicineLabelClassification({
    required this.kind,
    required this.confidence,
  });
}

class MedicineLabelResult {
  final String name;
  final String dosage;
  final double confidence;
  final double nameConfidence;
  final double dosageConfidence;
  final String rawText;
  final MedicineLabelKind kind;
  final ScanSource source;
  final String? barcode;
  final bool strengthConflict;
  final bool strengthNeedsReview;
  final bool nameConflict;
  final String? alternativeName;
  final List<String> activeIngredients;

  const MedicineLabelResult({
    required this.name,
    required this.dosage,
    required this.confidence,
    required this.nameConfidence,
    required this.dosageConfidence,
    required this.rawText,
    this.kind = MedicineLabelKind.medicine,
    this.source = ScanSource.ocr,
    this.barcode,
    this.strengthConflict = false,
    this.strengthNeedsReview = false,
    this.nameConflict = false,
    this.alternativeName,
    this.activeIngredients = const [],
  });

  MedicineLabelResult withRawText(String value) => MedicineLabelResult(
    name: name,
    dosage: dosage,
    confidence: confidence,
    nameConfidence: nameConfidence,
    dosageConfidence: dosageConfidence,
    rawText: value,
    kind: kind,
    source: source,
    barcode: barcode,
    strengthConflict: strengthConflict,
    strengthNeedsReview: strengthNeedsReview,
    nameConflict: nameConflict,
    alternativeName: alternativeName,
    activeIngredients: activeIngredients,
  );

  /// High-confidence labels confirm directly; medium ones ask the user to
  /// double-check the details. Low-confidence results never reach here — the
  /// parser rejects them.
  bool get isHighConfidence => confidence >= 0.75;
  bool get isMediumConfidence => confidence < 0.75;

  bool get requiresDosageInput =>
      strengthConflict ||
      strengthNeedsReview ||
      activeIngredients.length > 1 ||
      dosage.trim().isEmpty;

  bool get requiresNameReview => nameConflict;

  String get dosagePrompt => requiresDosageInput
      ? strengthConflict
            ? 'Scans disagree on the strength. Check the label and enter the amount and unit.'
            : activeIngredients.length > 1
            ? 'This medicine has multiple active strengths. Review the label and enter the administered dose.'
            : strengthNeedsReview
            ? 'The strength reading looks unusual. Check the label and enter the amount and unit.'
            : 'Strength not visible. Enter the amount in mg, g, mcg, or mL.'
      : '';

  /// The label carries a strength expression like "100 mg / 5 mL" — which
  /// part is the real per-dose amount is ambiguous, so the user should pick.
  bool get doseNeedsChoice {
    if (activeIngredients.length > 1) return false;
    final parsed = Dosage.parse(dosage);
    return parsed?.hasStrength == true && parsed?.secondValue != null;
  }
}

class MedicineLabelParser {
  static const int _maxRawTextLength = 12000;
  static final RegExp _strengthEvidence = RegExp(
    r'\b\d+(?:[.,]\d+)?\s*(?:mg|ml|g|mcg)\b',
    caseSensitive: false,
  );

  /// Keeps each printed ingredient separate. A conjunction is treated as an
  /// ingredient separator only when both sides contain a plausible name.
  List<String> splitCombinationIngredients(String text) {
    final parts = text
        .split(RegExp(r'\s*(?:\+|&|\band\b)\s*', caseSensitive: false))
        .map((part) => part.trim())
        .where((part) => RegExp(r'^[A-Za-z][A-Za-z ]{3,}$').hasMatch(part))
        .toList();
    return parts.length >= 2 ? parts : const [];
  }

  /// Resolve a package against local rows after OCR. The SQL search returns
  /// possible rows; only an exact observed name or a long cut suffix is used.
  /// A catalog strength never fills an unreadable printed strength.
  Future<MedicineLabelResult?> resolveCatalogPackage(
    String rawText,
    MedicineLabelResult? parsed, {
    Future<List<Map<String, Object?>>> Function(String)? lookup,
  }) async {
    final cleaned = const OcrTextCleanup().clean(rawText).text;
    final lines = cleaned.split(RegExp(r'[\r\n]+'));
    final queries = <String>[];
    void addQuery(String value) {
      final query = value
          .replaceAll(_dosagePattern, ' ')
          .replaceAll(RegExp(r'[^A-Za-z+& ]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .replaceAll(RegExp(r'[+&\s]+$'), '')
          .trim();
      if (query.length < 5 ||
          queries.any(
            (existing) => existing.toLowerCase() == query.toLowerCase(),
          )) {
        return;
      }
      queries.add(query);
    }

    // A parsed medicine name is usually the strongest single lookup hint.
    // A few nearby text lines can add a printed brand/generic pair, but
    // querying every OCR line made one scan issue up to two dozen serial SQL
    // searches, including boilerplate from the package.
    if (parsed != null) addQuery(parsed.name);
    for (final line in lines.take(12)) {
      if (queries.length >= 4) break;
      addQuery(line);
    }

    final observed = <String>[];
    final normalizedInnAliases = <String>{};
    final rows = <Map<String, Object?>>[];
    for (final query in queries) {
      observed.add(query.toLowerCase());
      final lookupKey = const OcrTextCleanup().normalizeInnForLookup(query);
      Future<List<Map<String, Object?>>> find(String key) => lookup != null
          ? lookup(key)
          : DatabaseHelper().findMedicines(key, limit: 8);
      var found = await find(query);
      if (found.isEmpty && lookupKey != query) {
        found = await find(lookupKey);
        if (found.isNotEmpty) {
          observed.add(lookupKey.toLowerCase());
          normalizedInnAliases.add(lookupKey.toLowerCase());
        }
      }
      rows.addAll(found);
    }
    if (rows.isEmpty) return parsed?.withRawText(rawText);
    final unique = <int, Map<String, Object?>>{
      for (final row in rows)
        if (row['id'] is int) row['id'] as int: row,
    };
    bool visible(String value) {
      final candidate = value
          .toLowerCase()
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (candidate.isEmpty) return false;
      return observed.any(
        (query) =>
            query == candidate ||
            (!normalizedInnAliases.contains(query) &&
                query.length >= 6 &&
                candidate.contains(query)),
      );
    }

    final matching = unique.values
        .where(
          (row) =>
              visible(row['brand_name']?.toString() ?? '') ||
              visible(row['generic_name']?.toString() ?? ''),
        )
        .toList();
    if (matching.isEmpty) return parsed?.withRawText(rawText);
    matching.sort((a, b) {
      int rank(Map<String, Object?> row) =>
          (visible(row['brand_name']?.toString() ?? '') ? 2 : 0) +
          (visible(row['generic_name']?.toString() ?? '') ? 1 : 0);
      return rank(b).compareTo(rank(a));
    });
    final row = matching.first;
    final brand = row['brand_name']?.toString().trim() ?? '';
    final generic = row['generic_name']?.toString().trim() ?? '';
    final brandSeen = visible(brand);
    final exactSeen =
        observed.contains(brand.toLowerCase()) ||
        observed.contains(generic.toLowerCase());
    final name = brandSeen
        ? brand
        : generic.isNotEmpty
        ? generic
        : brand;
    final printedStrengths = _dosagePattern
        .allMatches(cleaned)
        .map((match) => _normalizeDosage(match.group(0)!))
        .toSet()
        .toList();
    final ingredients = splitCombinationIngredients(generic);
    final ambiguousStrengths =
        ingredients.length <= 1 && printedStrengths.length > 1;
    final strength = ambiguousStrengths
        ? ''
        : ingredients.length > 1 && printedStrengths.length == 2
        ? printedStrengths.join(' + ')
        : printedStrengths.isNotEmpty
        ? printedStrengths.first
        : parsed?.dosage ?? '';
    return MedicineLabelResult(
      name: name,
      dosage: strength,
      confidence: exactSeen
          ? (parsed?.confidence ?? 0.76).clamp(0.0, 0.92)
          : (parsed?.confidence ?? 0.70).clamp(0.0, 0.72),
      nameConfidence: exactSeen ? 0.95 : 0.72,
      dosageConfidence: strength.isEmpty
          ? 0
          : (parsed?.dosageConfidence ?? 0.85),
      rawText: rawText,
      kind: MedicineLabelKind.medicine,
      source: ScanSource.localMatch,
      strengthConflict:
          ambiguousStrengths || (parsed?.strengthConflict ?? false),
      strengthNeedsReview: parsed?.strengthNeedsReview ?? false,
      activeIngredients: ingredients.isEmpty && generic.isNotEmpty
          ? [generic]
          : ingredients,
    );
  }

  /// Reconciles two independent OCR reads. Catalog evidence outranks visual
  /// confidence; a close disagreement remains visible for clinical review.
  MedicineLabelResult? reconcileCandidates(
    MedicineLabelResult? mlKit,
    MedicineLabelResult? alternate, {
    double mlKitVisualConfidence = 0.5,
    double alternateVisualConfidence = 0.5,
  }) {
    if (mlKit == null) return alternate;
    if (alternate == null) return mlKit;
    double score(MedicineLabelResult result, double visual) {
      final catalog = PhDrugCatalog.instance.findBest(result.name);
      final catalogPoints = catalog?.exact == true
          ? 4.0
          : catalog != null
          ? 3.0
          : 0.0;
      return catalogPoints +
          (_strengthEvidence.hasMatch(result.rawText) ? 1.0 : 0.0) +
          visual.clamp(0.0, 1.0) * 0.5 +
          result.nameConfidence.clamp(0.0, 1.0) * 0.25;
    }

    final leftScore = score(mlKit, mlKitVisualConfidence);
    final rightScore = score(alternate, alternateVisualConfidence);
    final winner = leftScore >= rightScore ? mlKit : alternate;
    final other = identical(winner, mlKit) ? alternate : mlKit;
    if (_medicineIdentity(winner.name) == _medicineIdentity(other.name)) {
      return mergeReads([winner], [other]).first;
    }
    final close = (leftScore - rightScore).abs() < 0.35;
    if (!close) return winner;
    return MedicineLabelResult(
      name: winner.name,
      dosage: winner.dosage,
      confidence: winner.confidence.clamp(0.0, 0.74),
      nameConfidence: winner.nameConfidence.clamp(0.0, 0.74),
      dosageConfidence: winner.dosageConfidence,
      rawText: winner.rawText,
      kind: winner.kind,
      source: winner.source,
      strengthConflict: winner.strengthConflict,
      strengthNeedsReview: winner.strengthNeedsReview,
      nameConflict: true,
      alternativeName: other.name,
    );
  }

  static final RegExp _dosagePattern = RegExp(
    r'\b(\d+(?:[.,]\d+)?)\s*(mcg|mg|g|ml|mL|iu|IU|units?|%|drop|drops|puff|puffs)\b(?:\s*/\s*(\d+(?:[.,]\d+)?)?\s*(mcg|mg|g|ml|mL|iu|IU|units?|%|drop|drops|puff|puffs)\b)?',
    caseSensitive: false,
  );

  /// Converts ML Kit block geometry into a stable reading order before text
  /// parsing. Nearby baselines form a row; rows are ordered top-to-bottom and
  /// words within a row left-to-right, preserving side-by-side strength text.
  MedicineLabelResult? parseRecognizedText(RecognizedText recognized) =>
      parse(layoutRecognizedText(recognized));

  String layoutRecognizedText(RecognizedText recognized) {
    final lines = <({Rect box, String text})>[];
    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        final text = line.text.trim();
        if (text.isNotEmpty) lines.add((box: line.boundingBox, text: text));
      }
    }
    lines.sort((a, b) => a.box.center.dy.compareTo(b.box.center.dy));
    final rows = <List<({Rect box, String text})>>[];
    for (final line in lines) {
      List<({Rect box, String text})>? row;
      for (final candidate in rows) {
        final centerY =
            candidate
                .map((item) => item.box.center.dy)
                .reduce((a, b) => a + b) /
            candidate.length;
        final rowHeight = candidate
            .map((item) => item.box.height)
            .reduce((a, b) => a > b ? a : b);
        if ((centerY - line.box.center.dy).abs() <=
            math.max(12.0, math.max(rowHeight, line.box.height) * .75)) {
          row = candidate;
          break;
        }
      }
      if (row == null) {
        rows.add([line]);
      } else {
        row.add(line);
      }
    }
    return rows
        .map((row) {
          row.sort((a, b) => a.box.left.compareTo(b.box.left));
          return row.map((line) => line.text).join(' ');
        })
        .join('\n');
  }

  static final RegExp _prescriptionStrengthPattern = RegExp(
    r'\b\d+(?:[.,]\d+)?\s*(?:mg|ml|mcg|g)\b(?:\s*/\s*\d+(?:[.,]\d+)?\s*(?:mg|ml|mcg|g)\b)?',
    caseSensitive: false,
  );
  static final RegExp _packagingMetadataLine = RegExp(
    r'^\s*(?:batch\s*(?:no\.?|number)?|lot\s*(?:no\.?|number)?|mfg\.?|manufactur(?:ed|ing)\s*date|exp(?:\.?|iry|iration)?\s*(?:date)?|drp[-\s]?\d+)\b',
    caseSensitive: false,
  );
  static final RegExp _therapeuticClassLine = RegExp(
    r'^\s*(?:analgesic|antipyretic|anti[-\s]?inflammatory|anilide)(?:[\s/(),-]+(?:analgesic|antipyretic|anti[-\s]?inflammatory|anilide))*[\s/(),-]*$',
    caseSensitive: false,
  );
  static final RegExp _parentheticalBrandPair = RegExp(
    r'\b[A-Za-z][A-Za-z0-9 -]{2,}\s*\([^)]{2,}\)',
  );

  static final RegExp _lettersPattern = RegExp(r'[A-Za-z]');
  static final RegExp _nameTokenPattern = RegExp(
    r'^[A-Za-z][A-Za-z0-9+\-/.]*$',
  );

  static const Set<String> _medicineSignals = {
    'tablet',
    'tablets',
    'tab',
    'tabs',
    'capsule',
    'capsules',
    'cap',
    'caps',
    'syrup',
    'suspension',
    'solution',
    'injection',
    'cream',
    'ointment',
    'drops',
    'oral',
    'dose',
    'dosage',
    'prescription',
    'rx',
    'pharmacy',
    'generic',
    'medicine',
    'medication',
    'drug',
    'take',
    'chewable',
    'extended',
    'release',
  };

  static const Set<String> _philippineBrands = {
    'biogesic',
    'neozep',
    'decongestant',
    'bioflu',
    'sinecod',
    'solmux',
    'carbocisteine',
    'ambrox',
    'ambroxol',
    'mucosolvon',
    'nospan',
    'diatabs',
    'diatab',
    'loperamide',
    'natravox',
    'zithromax',
    'azithral',
    'kremil',
    'kremil s',
    'maalox',
    'antacid',
    'ranitidine',
    'erceflora',
    'erectera',
    'lactobacillus',
    'probiotic',
    'phensedyl',
    'benadryl',
    'antihistamine',
    'diclofenac',
    'mefenamic',
    'ponstan',
    'dolfenal',
    'cloxacillin',
    'cloxa',
    'coamoxiclav',
    'augmentin',
    'tuseran',
    'tuseran forte',
    'cetirizine',
    'loratadine',
    'alnix',
    'lagundi',
    'sambong',
    'lagundi tablet',
    'sambong tablet',
    'ascorbic acid',
    'vitamin c',
    'ferrous sulfate',
    'iron',
    'mefenamic acid',
    'ibuprofen',
    'paracetamol',
    'acetaminophen',
    'amoxicillin',
    'metformin',
    'amlodipine',
    'losartan',
    'omeprazole',
    'simvastatin',
    'atorvastatin',
    'rosuvastatin',
    'calcium carbonate',
    'caltrate',
    'calciferol',
    'cotrimoxazole',
    'bactrim',
    'clarithromycin',
    'klaz',
    'cefalexin',
    'cephalexin',
    'cefuroxime',
    'cefixime',
    'suprax',
    'phenylephrine',
    'chlorphenamine',
    'chlorpheniramine',
    'phenylpropanolamine',
    'leflunomide',
    'methotrexate',
    'allopurinol',
    'colchicine',
    'febuxostat',
    'fluoxetine',
    'escitalopram',
    'sertraline',
    'aluminum hydroxide',
    'magnesium hydroxide',
    'simethicone',
    'furosemide',
    'captopril',
    'enalapril',
    'clonazepam',
    'diazepam',
    'bromazepam',
    'salbutamol',
    'ventolin',
    'wheezrel',
    'nebusal',
    'berotec',
    'atrovent',
    'ipratropium',
    'budesonide',
    'fluticasone',
    'carvedilol',
    'bisoprolol',
    'metoprolol',
    'valsartan',
    'telmisartan',
    'irbesartan',
    'clopidogrel',
    'aspirin',
    'warfarin',
    'rivaroxaban',
    'ticagrelor',
    'brilinta',
    'lovastatin',
    'fenofibrate',
    'gemfibrozil',
    'glimepiride',
    'gliclazide',
    'sitagliptin',
    'empagliflozin',
    'insulin',
    'lantus',
    'novorapid',
    'humalog',
    'prednisone',
    'prednisolone',
    'methylprednisolone',
    'medrol',
    'tranexamic acid',
    'hemostan',
    'betahistine',
    'meclizine',
    'bonamine',
    'domperidone',
    'metoclopramide',
    'plasil',
    'buscopan',
    'hyoscine',
    'dicyclomine',
    'isoprenaline',
    'isoproterenol',
    'lidocaine',
  };

  static const List<_CommonMedicineProfile> _commonMedicineProfiles = [
    _CommonMedicineProfile('Paracetamol', [
      'paracetamol',
      'acetaminophen',
      'biogesic',
      'tylenol',
      'panadol',
      'calpol',
    ]),
    _CommonMedicineProfile('Metoprolol', ['metoprolol', 'betaloc']),
    _CommonMedicineProfile('Dorzolamide', ['dorzolamide', 'dorzolamidum']),
    _CommonMedicineProfile('Cimetidine', ['cimetidine']),
    _CommonMedicineProfile('Oxprenolol', ['oxprenolol', 'oxprelol']),
    _CommonMedicineProfile('Vitamin C', [
      'vitamin c',
      'ascorbic acid',
      'ceelin',
      'potencee',
      'enervon c',
      'immunpro',
    ]),
    _CommonMedicineProfile('Amoxicillin', [
      'amoxicillin',
      'amoxil',
      'hifenac',
      'moxilen',
    ]),
    _CommonMedicineProfile('Metformin', [
      'metformin',
      'glucophage',
      'fortamet',
      'riomet',
    ]),
    _CommonMedicineProfile('Ibuprofen', [
      'ibuprofen',
      'advil',
      'motrin',
      'medicol',
      'nurofen',
    ]),
    _CommonMedicineProfile('Mefenamic Acid', [
      'mefenamic acid',
      'ponstan',
      'dolfenal',
    ]),
    _CommonMedicineProfile('Amlodipine', ['amlodipine', 'norvasc', 'amlife']),
    _CommonMedicineProfile('Losartan', ['losartan', 'cozaar', 'lifezar']),
    _CommonMedicineProfile('Cetirizine', [
      'cetirizine',
      'zyrtec',
      'allerkid',
      'alerid',
    ]),
    _CommonMedicineProfile('Loratadine', ['loratadine', 'claritin', 'allerta']),
    _CommonMedicineProfile('Omeprazole', ['omeprazole', 'losec', 'prilosec']),
    _CommonMedicineProfile('Simvastatin', [
      'simvastatin',
      'zocor',
      'simvahexal',
    ]),
    _CommonMedicineProfile('Atorvastatin', ['atorvastatin', 'lipitor', 'ator']),
    _CommonMedicineProfile('Rosuvastatin', ['rosuvastatin', 'crestor']),
    _CommonMedicineProfile('Aspirin', [
      'aspirin',
      'acetylsalicylic acid',
      'bayer aspirin',
    ]),
    _CommonMedicineProfile('Clopidogrel', ['clopidogrel', 'plavix']),
    _CommonMedicineProfile('Azithromycin', [
      'azithromycin',
      'zithromax',
      'azithral',
    ]),
    _CommonMedicineProfile('Cefalexin', ['cefalexin', 'cephalexin', 'keflex']),
    _CommonMedicineProfile('Cefuroxime', ['cefuroxime', 'zinnat']),
    _CommonMedicineProfile('Cefixime', ['cefixime', 'suprax']),
    _CommonMedicineProfile('Co-amoxiclav', [
      'coamoxiclav',
      'co amoxiclav',
      'amoxiclav',
      'augmentin',
    ]),
    _CommonMedicineProfile('Carbocisteine', ['carbocisteine', 'solmux']),
    _CommonMedicineProfile('Ambroxol', ['ambroxol', 'mucosolvan', 'ambrox']),
    _CommonMedicineProfile('Loperamide', ['loperamide', 'diatabs', 'imodium']),
    _CommonMedicineProfile('Hyoscine', ['hyoscine', 'buscopan']),
    _CommonMedicineProfile('Domperidone', ['domperidone', 'motilium']),
    _CommonMedicineProfile('Metoclopramide', ['metoclopramide', 'plasil']),
    _CommonMedicineProfile('Salbutamol', [
      'salbutamol',
      'albuterol',
      'ventolin',
    ]),
    _CommonMedicineProfile('Prednisone', ['prednisone']),
    _CommonMedicineProfile('Prednisolone', ['prednisolone']),
    _CommonMedicineProfile('Allopurinol', ['allopurinol', 'zyloprim']),
    _CommonMedicineProfile('Colchicine', ['colchicine']),
    _CommonMedicineProfile('Levothyroxine', [
      'levothyroxine',
      'eltroxin',
      'synthroid',
    ]),
    _CommonMedicineProfile('Glimepiride', ['glimepiride', 'amaryl']),
    _CommonMedicineProfile('Gliclazide', ['gliclazide', 'diamicron']),
    _CommonMedicineProfile('Sitagliptin', ['sitagliptin', 'januvia']),
    _CommonMedicineProfile('Empagliflozin', ['empagliflozin', 'jardiance']),
    _CommonMedicineProfile('Ferrous Sulfate', [
      'ferrous sulfate',
      'ferrous sulphate',
      'iron',
    ]),
    _CommonMedicineProfile('Folic Acid', ['folic acid', 'folate']),
    _CommonMedicineProfile('Calcium Carbonate', [
      'calcium carbonate',
      'caltrate',
      'tums',
    ]),
    _CommonMedicineProfile('Vitamin D3', ['vitamin d3', 'cholecalciferol']),
    _CommonMedicineProfile('Vitamin B Complex', [
      'vitamin b complex',
      'b complex',
      'neurobion',
    ]),
  ];

  /// A live preview may see only the beginning of a medicine name. A prefix
  /// is useful for framing, but never supplies a final name or strength.
  String? previewMedicineName(String text) {
    final catalog = PhDrugCatalog.instance;
    if (catalog.isLoaded) {
      final lines = text
          .split(RegExp(r'[\r\n]+'))
          .take(12)
          .where((line) => line.length <= 100)
          .toList(growable: false);
      for (final line in lines) {
        final match = catalog.findBest(line, allowFuzzy: false);
        if (match?.exact == true) return match!.canonicalName;
      }
      for (final line in lines) {
        final match = catalog.findTentativeGeneric(line);
        if (match != null) return match.canonicalName;
      }
      final spanning = catalog.findTentativeGeneric(text);
      if (spanning != null) return spanning.canonicalName;
    }
    final tokens = RegExp(
      r'[A-Za-z]{4,}',
    ).allMatches(text).map((match) => match.group(0)!.toLowerCase());
    for (final token in tokens) {
      final matches = _commonMedicineProfiles
          .where((profile) {
            return [profile.canonicalName, ...profile.aliases].any((alias) {
              final firstWord = alias
                  .toLowerCase()
                  .split(RegExp(r'[^a-z]+'))
                  .first;
              return firstWord.length >= token.length &&
                  firstWord.startsWith(token);
            });
          })
          .toList(growable: false);
      if (matches.length == 1) return matches.single.canonicalName;
    }
    return null;
  }

  /// Extra generic and brand terms used only as medicine evidence. Doses are
  /// not inferred from this broad list because strengths vary by patient and
  /// product.
  static const Set<String> _commonMedicineTerms = {
    'abatacept',
    'abilify',
    'acarbose',
    'accupril',
    'accutane',
    'aciclovir',
    'actos',
    'acyclovir',
    'adalimumab',
    'adapalene',
    'advair',
    'advil',
    'aggrenox',
    'albendazole',
    'albuterol',
    'aldactone',
    'alendronate',
    'alfuzosin',
    'alimemazine',
    'allerta',
    'allopurinol',
    'alprazolam',
    'alvedon',
    'amantadine',
    'amaryl',
    'ambroxol',
    'amiodarone',
    'amitriptyline',
    'amlodipine',
    'amoxicillin',
    'amoxiclav',
    'amoxil',
    'amphetamine',
    'anastrozole',
    'androgel',
    'apixaban',
    'arava',
    'arcoxia',
    'aricept',
    'aripiprazole',
    'asacol',
    'ascorbic acid',
    'aspirin',
    'atenolol',
    'ativan',
    'atorvastatin',
    'atrovent',
    'augmentin',
    'azathioprine',
    'azithral',
    'azithromycin',
    'baclofen',
    'bactrim',
    'bactroban',
    'beclomethasone',
    'benadryl',
    'benazepril',
    'berotec',
    'betahistine',
    'betamethasone',
    'biogesic',
    'bioflu',
    'bisacodyl',
    'bisoprolol',
    'bonamine',
    'brilinta',
    'bromazepam',
    'budesonide',
    'bumetanide',
    'buscopan',
    'calcipotriol',
    'calcitriol',
    'calpol',
    'caltrate',
    'candesartan',
    'captopril',
    'carbamazepine',
    'carbocisteine',
    'carvedilol',
    'ceclor',
    'cefadroxil',
    'cefalexin',
    'cefixime',
    'cefpodoxime',
    'ceftriaxone',
    'cefuroxime',
    'celebrex',
    'celecoxib',
    'cephalexin',
    'cetirizine',
    'cevimeline',
    'chloramphenicol',
    'chlordiazepoxide',
    'chlorphenamine',
    'chlorpheniramine',
    'chlorthalidone',
    'cholecalciferol',
    'ciprofloxacin',
    'citalopram',
    'clarinase',
    'clarithromycin',
    'claritin',
    'clindamycin',
    'clobetasol',
    'clonazepam',
    'clonidine',
    'clopidogrel',
    'clotrimazole',
    'cloxacillin',
    'cloxa',
    'co amoxiclav',
    'coamoxiclav',
    'colchicine',
    'combivent',
    'concerta',
    'cozaar',
    'crestor',
    'cyanocobalamin',
    'cyclobenzaprine',
    'dapagliflozin',
    'dexamethasone',
    'dextromethorphan',
    'diazepam',
    'diamicron',
    'diatab',
    'diatabs',
    'diclofenac',
    'digoxin',
    'diltiazem',
    'diphenhydramine',
    'dipyridamole',
    'dolfenal',
    'domperidone',
    'donepezil',
    'doxycycline',
    'dulcolax',
    'duloxetine',
    'duphalac',
    'dutasteride',
    'edoxaban',
    'efavirenz',
    'enalapril',
    'enervon c',
    'entecavir',
    'epinephrine',
    'erceflora',
    'escitalopram',
    'esomeprazole',
    'estradiol',
    'etoricoxib',
    'ezetimibe',
    'famotidine',
    'febuxostat',
    'felodipine',
    'fenofibrate',
    'fentanyl',
    'ferrous sulfate',
    'ferrous sulphate',
    'fexofenadine',
    'finasteride',
    'flagyl',
    'fluconazole',
    'fluoxetine',
    'fluticasone',
    'folic acid',
    'furosemide',
    'gabapentin',
    'galvus',
    'gemfibrozil',
    'glibenclamide',
    'gliclazide',
    'glimepiride',
    'glipizide',
    'glucophage',
    'glyceryl trinitrate',
    'guaifenesin',
    'haloperidol',
    'hemostan',
    'humalog',
    'hydralazine',
    'hydrochlorothiazide',
    'hydrocortisone',
    'hydroxychloroquine',
    'hyoscine',
    'ibandronate',
    'ibuprofen',
    'imodium',
    'immunpro',
    'indapamide',
    'indomethacin',
    'insulin',
    'ipratropium',
    'irbesartan',
    'isosorbide dinitrate',
    'isosorbide mononitrate',
    'januvia',
    'jardiance',
    'keflex',
    'klaz',
    'kremil',
    'kremil s',
    'labetalol',
    'lactobacillus',
    'lactulose',
    'lagundi',
    'lantus',
    'lansoprazole',
    'leflunomide',
    'letrozole',
    'levofloxacin',
    'levocetirizine',
    'levodopa',
    'levonorgestrel',
    'levothyroxine',
    'lidocaine',
    'linagliptin',
    'lipitor',
    'lisinopril',
    'loperamide',
    'loratadine',
    'lorazepam',
    'losartan',
    'lovastatin',
    'maalox',
    'mebendazole',
    'meclizine',
    'medicol',
    'medrol',
    'mefenamic acid',
    'meloxicam',
    'memantine',
    'metformin',
    'methimazole',
    'methotrexate',
    'methyldopa',
    'methylphenidate',
    'methylprednisolone',
    'metoclopramide',
    'metoprolol',
    'metronidazole',
    'montelukast',
    'motilium',
    'motrin',
    'mucosolvan',
    'mupirocin',
    'mycophenolate',
    'naproxen',
    'natravox',
    'nebusal',
    'neozep',
    'neurobion',
    'nifedipine',
    'nitrofurantoin',
    'nospan',
    'novorapid',
    'nurofen',
    'olanzapine',
    'olmesartan',
    'omeprazole',
    'ondansetron',
    'oseltamivir',
    'panadol',
    'pantoprazole',
    'paracetamol',
    'penicillin',
    'phenobarbital',
    'phenylephrine',
    'phenylpropanolamine',
    'phensedyl',
    'phenytoin',
    'pioglitazone',
    'plasil',
    'plavix',
    'potencee',
    'prednisolone',
    'prednisone',
    'pregabalin',
    'prilosec',
    'probiotic',
    'propranolol',
    'quetiapine',
    'ramipril',
    'ranitidine',
    'repaglinide',
    'rivaroxaban',
    'rosuvastatin',
    'salbutamol',
    'sambong',
    'senna',
    'sertraline',
    'sildenafil',
    'simethicone',
    'simvastatin',
    'sinecod',
    'sitagliptin',
    'solmux',
    'spironolactone',
    'sucralfate',
    'suprax',
    'synthroid',
    'tacrolimus',
    'tadalafil',
    'tamoxifen',
    'tamsulosin',
    'telmisartan',
    'tenofovir',
    'terazosin',
    'terbinafine',
    'theophylline',
    'ticagrelor',
    'tizanidine',
    'tramadol',
    'tranexamic acid',
    'triamcinolone',
    'trimetazidine',
    'trimethoprim',
    'tums',
    'tuseran',
    'tuseran forte',
    'tylenol',
    'ursodeoxycholic acid',
    'valacyclovir',
    'valsartan',
    'venlafaxine',
    'ventolin',
    'verapamil',
    'vitamin b complex',
    'vitamin c',
    'vitamin d3',
    'warfarin',
    'wheezrel',
    'xarelto',
    'zinnat',
    'zithromax',
    'zocor',
    'zolpidem',
    'zyrtec',
  };

  static const Set<String> _knownMedicineWords = {
    'acetaminophen',
    'paracetamol',
    'ibuprofen',
    'amoxicillin',
    'metformin',
    'amlodipine',
    'losartan',
    'atorvastatin',
    'omeprazole',
    'simvastatin',
    'lisinopril',
    'azithromycin',
    'cetirizine',
    'loratadine',
    'aspirin',
    'gabapentin',
    'levothyroxine',
    'albuterol',
    'hydrochlorothiazide',
  };

  static const Set<String> _nameStopWords = {
    'tablet',
    'tablets',
    'capsule',
    'capsules',
    'syrup',
    'suspension',
    'solution',
    'oral',
    'take',
    'dose',
    'dosage',
    'prescription',
    'rx',
    'pharmacy',
    'generic',
    'medicine',
    'medication',
    'drug',
    'each',
    'contains',
    'label',
    'directions',
    'warning',
    'keep',
    'store',
    'expiry',
    'expires',
    'lot',
    'batch',
    'manufactured',
    'analgesic',
    'antipyretic',
    'antiinflammatory',
    'anilide',
  };

  static const Set<String> _nonMedicineSignals = {
    'price',
    'sale',
    'discount',
    'calories',
    'nutrition',
    'battery',
    'charger',
    'receipt',
    'invoice',
    'total',
    'subtotal',
    'tax',
    'vat',
    'change',
    'cash',
    'credit',
    'payment',
    'bill',
    'refund',
    'coupon',
    'promo',
    'warranty',
    'guarantee',
    'shipping',
    'delivery',
    'customer',
    'service',
    'phone',
    'number',
    'address',
    'email',
    'parking',
    'ticket',
    'admission',
    'menu',
    'order',
    'reservation',
    'ingredients',
    'serving',
    'portion',
    'caloric',
  };

  static const Set<String> _alcoholSignals = {
    'alcohol',
    'beer',
    'brandy',
    'champagne',
    'gin',
    'liquor',
    'rum',
    'sake',
    'spirits',
    'vodka',
    'whiskey',
    'whisky',
    'wine',
  };

  static const Set<String> _perfumeSignals = {
    'aftershave',
    'cologne',
    'eau de parfum',
    'eau de toilette',
    'fragrance',
    'parfum',
    'perfume',
  };

  MedicineLabelClassification classify(String rawText) {
    if (rawText.length > _maxRawTextLength) {
      return const MedicineLabelClassification(
        kind: MedicineLabelKind.unknown,
        confidence: 0,
      );
    }
    final text = _normalizedWords(rawText);
    if (text.isEmpty) {
      return const MedicineLabelClassification(
        kind: MedicineLabelKind.unknown,
        confidence: 0,
      );
    }

    final alcoholHits = _keywordHits(text, _alcoholSignals);
    final perfumeHits = _keywordHits(text, _perfumeSignals);
    final medicineHits =
        _keywordHits(text, _medicineSignals) +
        (_findCommonMedicineMatch(rawText)?.confidence ?? 0) +
        (PhDrugCatalog.instance.findBest(rawText)?.confidence ?? 0);
    if (alcoholHits > medicineHits && alcoholHits >= 1) {
      return MedicineLabelClassification(
        kind: MedicineLabelKind.alcohol,
        confidence: (0.65 + alcoholHits * 0.12).clamp(0.0, 0.98),
      );
    }
    if (perfumeHits > medicineHits && perfumeHits >= 1) {
      return MedicineLabelClassification(
        kind: MedicineLabelKind.perfume,
        confidence: (0.65 + perfumeHits * 0.12).clamp(0.0, 0.98),
      );
    }
    if (medicineHits > 0) {
      return MedicineLabelClassification(
        kind: MedicineLabelKind.medicine,
        confidence: medicineHits.clamp(0.0, 0.98),
      );
    }
    return const MedicineLabelClassification(
      kind: MedicineLabelKind.unknown,
      confidence: 0.2,
    );
  }

  double _keywordHits(String text, Set<String> keywords) {
    return keywords
        .where((keyword) {
          return RegExp(
            r'(^|\s)' + RegExp.escape(keyword) + r'($|\s)',
          ).hasMatch(text);
        })
        .length
        .toDouble();
  }

  MedicineLabelResult? parse(String rawText) {
    if (rawText.length > _maxRawTextLength) return null;
    final sanitizedText = _sanitizePackagingText(rawText);
    final lines = sanitizedText
        .split(RegExp(r'[\r\n]+'))
        .map(_normalizeLine)
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;

    final fullText = lines.join('\n');
    final normalizedFullText = fullText.toLowerCase();
    final catalogMatch = PhDrugCatalog.instance.findBest(
      const OcrTextCleanup().clean(fullText).text,
    );
    final classification = classify(rawText);
    if (classification.kind != MedicineLabelKind.medicine) return null;
    final nonMedScore = _nonMedicineScore(normalizedFullText);
    if (nonMedScore > 0.25) return null;

    final dosageMatches = _dosagePattern.allMatches(fullText).toList();
    if (dosageMatches.isEmpty) {
      final likelyName = _cleanName(lines.first);
      if (catalogMatch != null &&
          catalogMatch.exact &&
          (likelyName == null || !_hasKnownMedicineEvidence(likelyName))) {
        final confidence = catalogMatch.exact
            ? catalogMatch.confidence.clamp(0.0, 0.78)
            : 0.70;
        return MedicineLabelResult(
          name: catalogMatch.canonicalName,
          dosage: '',
          confidence: confidence,
          nameConfidence: catalogMatch.confidence.clamp(0.0, 0.95),
          dosageConfidence: 0,
          rawText: rawText,
          source: ScanSource.localMatch,
        );
      }
      final fallback = _findCommonMedicineMatch(fullText);
      if (fallback == null || fallback.confidence < 0.78) {
        return null;
      }

      return MedicineLabelResult(
        name: fallback.profile.canonicalName,
        // Never fill an unreadable strength from a common-dose lookup table.
        dosage: '',
        confidence: 0.58,
        nameConfidence: fallback.confidence.clamp(0.0, 0.78),
        dosageConfidence: 0,
        rawText: rawText,
        kind: classification.kind,
      );
    }

    _Candidate? best;
    for (final match in dosageMatches) {
      final dosage = _normalizeDosage(match.group(0)!);
      final lineIndex = _lineIndexForMatch(lines, match.start);
      final line = lines[lineIndex];
      final extractedName = _extractName(lines, lineIndex, line, match.start);
      final catalogCandidate =
          PhDrugCatalog.instance.findBest(line) ??
          (extractedName == null
              ? null
              : PhDrugCatalog.instance.findBest(extractedName));
      // A fuzzy regional hit must never replace an unfamiliar international
      // name. Exact catalog evidence is safe; fuzzy evidence requires a name
      // already supported by the local dictionary and dosage context.
      final catalogLineMatch =
          catalogCandidate == null ||
              catalogCandidate.exact ||
              (extractedName != null &&
                  _hasKnownMedicineEvidence(extractedName) &&
                  dosage.isNotEmpty)
          ? catalogCandidate
          : null;
      final dictionaryMatch = _findCommonMedicineMatch(
        '$line\n$fullText',
        likelyName: extractedName,
      );
      final catalogName = catalogLineMatch?.canonicalName;
      final pairedName = _parentheticalBrandPair.hasMatch(line);
      final name = pairedName && catalogName != null
          ? catalogName
          : (extractedName != null && _hasKnownMedicineEvidence(extractedName))
          ? extractedName
          : catalogName ??
                dictionaryMatch?.profile.canonicalName ??
                extractedName;
      if (name == null) continue;

      final scored = _scoreCandidate(
        name: name,
        dosage: dosage,
        line: line,
        fullText: normalizedFullText,
        dictionaryConfidence: [
          dictionaryMatch?.confidence ?? 0,
          catalogLineMatch?.confidence ?? 0,
        ].reduce((a, b) => a > b ? a : b),
      );

      // A fuzzy catalog correction is useful for OCR typos, but it must stay
      // below the automatic-acceptance threshold and require confirmation.
      final overall = catalogLineMatch != null && !catalogLineMatch.exact
          ? scored.overall.clamp(0.0, 0.72)
          : scored.overall;
      final nameConfidence = catalogLineMatch != null && !catalogLineMatch.exact
          ? catalogLineMatch.confidence.clamp(0.0, 0.72)
          : scored.name;

      final candidate = _Candidate(
        name,
        dosage,
        overall,
        nameConfidence,
        scored.dosage,
      );
      if (best == null || candidate.confidence > best.confidence) {
        best = candidate;
      }
    }

    if (best == null) return null;

    final phBrandFound = _isPhDrug(best.name.toLowerCase());
    final threshold = phBrandFound ? 0.50 : 0.68;

    if (best.confidence < threshold) return null;

    final parsedDose = Dosage.parse(best.dosage);
    // A very large gram value is more likely a lost "m" in "mg" or a package
    // weight than a per-dose strength. Keep the OCR text visible, but require
    // the user to enter the strength rather than storing it automatically.
    final strengthNeedsReview =
        parsedDose?.unit == 'g' &&
        parsedDose?.value != null &&
        parsedDose!.value! >= 100 &&
        !parsedDose.hasStrength;

    return MedicineLabelResult(
      name: best.name,
      dosage: best.dosage,
      confidence: best.confidence.clamp(0, 1),
      nameConfidence: best.nameConfidence.clamp(0, 1),
      dosageConfidence: best.dosageConfidence.clamp(0, 1),
      rawText: rawText,
      kind: classification.kind,
      source: catalogMatch == null ? ScanSource.ocr : ScanSource.localMatch,
      strengthNeedsReview: strengthNeedsReview,
    );
  }

  /// Parses one medicine into the compact output model. Returns null if the
  /// existing conservative label rules cannot identify a medicine.
  ///
  /// Strength and frequency are copied only when present in the OCR text. In
  /// particular, a common-medicine fallback strength is never presented as an
  /// observed label value. Use [parseAllStructured] for multi-medicine text.
  ParsedMedicine? parseStructured(String rawText) {
    final result = parse(rawText);
    return result == null ? null : _toParsedMedicine(result);
  }

  /// A package has one medicine identity even when its label repeats around
  /// several pockets. Conflicting printed strengths require manual review.
  MedicineLabelResult? parsePackage(String rawText) {
    final result = parse(rawText);
    final catalogResult = _exactCatalogPackage(rawText, result);
    if (catalogResult != null) return catalogResult;
    final items = _dedupePrescriptionItems(parsePrescriptionItems(rawText));
    if (items.isEmpty) return result;
    final identities = items
        .map((item) => _medicineIdentity(item.drugName))
        .toSet();
    if (identities.length != 1) return result;
    final strengths = items
        .map(
          (item) => item.strength.toLowerCase().replaceAll(RegExp(r'\s+'), ''),
        )
        .toSet();
    if (strengths.length == 1) {
      if (result != null &&
          _medicineIdentity(result.name) == identities.single &&
          result.dosage.toLowerCase().replaceAll(RegExp(r'\s+'), '') ==
              strengths.single) {
        return result;
      }
      final item = items.first;
      return MedicineLabelResult(
        name: item.drugName,
        dosage: item.strength,
        confidence: (result?.confidence ?? 0.72).clamp(0.0, 0.72),
        nameConfidence: (result?.nameConfidence ?? 0.70).clamp(0.0, 0.72),
        dosageConfidence: 0.85,
        rawText: rawText,
        source: ScanSource.ocr,
      );
    }
    final name =
        result != null && _medicineIdentity(result.name) == identities.single
        ? result.name
        : items.first.drugName;
    return MedicineLabelResult(
      name: name,
      dosage: '',
      confidence: (result?.confidence ?? 0.7).clamp(0.0, 0.74),
      nameConfidence: result?.nameConfidence ?? 0.7,
      dosageConfidence: 0,
      rawText: rawText,
      source: result?.source ?? ScanSource.ocr,
      strengthConflict: true,
    );
  }

  /// Package identity comes from a printed catalog name. Strength is still
  /// taken only from OCR; several distinct strengths need a manual choice.
  MedicineLabelResult? _exactCatalogPackage(
    String rawText,
    MedicineLabelResult? parsed,
  ) {
    if (classify(rawText).kind != MedicineLabelKind.medicine ||
        _nonMedicineScore(_normalizedWords(rawText)) > 0.25) {
      return null;
    }
    final cleaned = const OcrTextCleanup().clean(rawText).text;
    final catalog = PhDrugCatalog.instance;
    final match = catalog.findBest(cleaned, allowFuzzy: false);
    if (match == null || !match.exact) return null;
    final identities = <String>{};
    for (final line in cleaned.split(RegExp(r'[\r\n]+')).take(12)) {
      final lineMatch = catalog.findBest(line, allowFuzzy: false);
      if (lineMatch?.exact != true) continue;
      identities.add(lineMatch!.product.genericName.toLowerCase().trim());
    }
    if (identities.length > 1) return null;
    final ingredients = splitCombinationIngredients(match.product.genericName);
    final strengths = _dosagePattern
        .allMatches(cleaned)
        .map((item) => _normalizeDosage(item.group(0)!))
        .toSet();
    final ambiguous = strengths.length > 1;
    return MedicineLabelResult(
      name: match.canonicalName,
      dosage: strengths.length == 1 ? strengths.single : '',
      confidence: ambiguous ? 0.72 : 0.78,
      nameConfidence: match.confidence.clamp(0.0, 0.95),
      dosageConfidence: strengths.length == 1 ? 0.85 : 0,
      rawText: rawText,
      source: ScanSource.localMatch,
      strengthConflict: ambiguous || (parsed?.strengthConflict ?? false),
      strengthNeedsReview: parsed?.strengthNeedsReview ?? false,
      activeIngredients:
          ingredients.isEmpty && match.product.genericName.isNotEmpty
          ? [match.product.genericName]
          : ingredients,
    );
  }

  ParsedMedicine? parsePackageStructured(String rawText) {
    final result = parsePackage(rawText);
    return result == null ? null : _toParsedMedicine(result);
  }

  /// Extracts independent structured results from multi-line text. Each row
  /// keeps only instruction lines already attached by [parseMany].
  List<ParsedMedicine> parseAllStructured(String rawText) =>
      parseMany(rawText).map(_toParsedMedicine).toList(growable: false);

  /// Detects prescription-like text without making clinical assumptions.
  /// Multiple medicine rows are strong evidence; a single row needs a
  /// prescription heading plus a direction/SIG line to avoid confusing a
  /// bottle label with a prescription page.
  PrescriptionDocumentDetection detectPrescriptionDocument(String rawText) {
    if (rawText.trim().isEmpty || rawText.length > _maxRawTextLength) {
      return const PrescriptionDocumentDetection(
        isPrescription: false,
        confidence: 0,
        items: [],
      );
    }
    final items = _dedupePrescriptionItems(parsePrescriptionItems(rawText));
    // A medicine carton often prints "Rx" beside its name and "capsule" or
    // "tablet" beside its strength. Neither is evidence of a prescription
    // page, so single-row detection requires an actual prescription heading.
    final hasHeader = RegExp(
      r'\b(?:prescription|medication\s+order|patient|prescriber|physician|doctor|pharmacy|refills?|directions?|sig)\b|\brx\s*(?:no\.?|number|#)(?:\s*[:#]?\s*\d+)?(?=\s|:|$)',
      caseSensitive: false,
    ).hasMatch(rawText);
    final hasDirections = RegExp(
      r'\b(?:take|give|use|apply|inhale|inject|swallow|chew|by\s+mouth|orally|topical|qd|od|bid|bd|tid|tds|qid|prn|once\s+(?:a|per)\s+day|twice\s+(?:a|per)\s+day|three\s+times\s+(?:a|per)\s+day|every\s+\d+\s*(?:hours?|days?))\b',
      caseSensitive: false,
    ).hasMatch(rawText);
    final distinctNames = items
        .map((item) {
          final catalogMatch = PhDrugCatalog.instance.findBest(
            item.drugName,
            allowFuzzy: false,
          );
          final genericName = catalogMatch?.exact == true
              ? catalogMatch!.product.genericName
              : '';
          return _medicineIdentity(
            genericName.isEmpty ? item.drugName : genericName,
          );
        })
        .toSet()
        .length;
    final multipleRows = distinctNames >= 2;
    final singlePrescriptionRow =
        distinctNames == 1 && hasHeader && hasDirections;
    final detected = multipleRows || singlePrescriptionRow;
    final confidence = multipleRows
        ? (distinctNames >= 3 ? 0.98 : 0.93)
        : singlePrescriptionRow
        ? 0.82
        : 0.0;
    return PrescriptionDocumentDetection(
      isPrescription: detected,
      confidence: confidence,
      items: List.unmodifiable(items),
    );
  }

  ParsedMedicine _toParsedMedicine(MedicineLabelResult result) {
    final strengthWasPrinted =
        _dosagePattern.hasMatch(result.rawText) &&
        !RegExp(
          r'\b(?:drops?|puffs?)\b',
          caseSensitive: false,
        ).hasMatch(result.dosage);
    final strength = strengthWasPrinted ? _normalizeDosage(result.dosage) : '';
    final instruction = const PrescriptionInstructionParser().parse(
      result.rawText,
    );
    final rawFrequency = instruction.isAsNeeded
        ? 'As needed'
        : instruction.frequency;
    final frequency = switch (rawFrequency) {
      'Once a day' => 'Once daily',
      'Twice a day' => 'Twice daily',
      'Three times a day' => 'Three times daily',
      final value? => value,
      null => '',
    };

    // Average confidence over fields that were actually observed. Missing
    // optional fields stay empty; they do not create false evidence or reduce
    // confidence in an otherwise clear medicine name.
    var weightedScore = result.nameConfidence * 0.7;
    var totalWeight = 0.7;
    if (strength.isNotEmpty) {
      weightedScore += result.dosageConfidence * 0.3;
      totalWeight += 0.3;
    }
    final score = (weightedScore / totalWeight)
        .clamp(0.0, result.confidence)
        .clamp(0.0, 1.0);
    final highConfidence =
        score >= 0.75 &&
        result.nameConfidence >= 0.75 &&
        (!strength.isNotEmpty || result.dosageConfidence >= 0.75) &&
        !result.strengthNeedsReview &&
        !result.strengthConflict &&
        !result.nameConflict;

    return ParsedMedicine(
      medicineName: result.name,
      strength: strength,
      frequency: frequency,
      confidenceScore: score,
      isHighConfidence: highConfidence,
    );
  }

  /// Extracts independent medicine candidates from a multi-line prescription.
  /// Each candidate is still reviewed separately; this method never creates
  /// schedules or assumes that one instruction applies to another medicine.
  List<MedicineLabelResult> parseMany(String rawText) {
    if (rawText.length > _maxRawTextLength) return const [];
    final normalizedText = _sanitizePackagingText(rawText);
    final lines = normalizedText
        .split(RegExp(r'[\r\n]+'))
        .map(_normalizeLine)
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty) return const [];

    // A prescription line has stronger structure than a whole-page bag of
    // words. Parse these rows first so an unfamiliar name can never be
    // replaced by an unrelated high-frequency catalog item.
    final structuredItems = _dedupePrescriptionItems(
      parsePrescriptionItems(normalizedText),
    );
    if (structuredItems.isNotEmpty) {
      return structuredItems
          .map(
            (item) => MedicineLabelResult(
              name: item.drugName,
              dosage: item.strength,
              confidence: item.strength.isEmpty ? 0.55 : 0.82,
              nameConfidence: 0.84,
              dosageConfidence: item.strength.isEmpty ? 0 : 0.90,
              rawText: item.rawLine,
              source: ScanSource.ocr,
            ),
          )
          .toList(growable: false);
    }

    // Make non-overlapping medicine blocks. Parsing every pair of adjacent
    // lines lets a SIG line borrow the strength of the *next* medicine and
    // creates a phantom candidate with the wrong unit.
    final blocks = <List<String>>[];
    for (final line in lines) {
      final standalone = parse(line);
      final startsMedicine =
          standalone != null &&
          !_instructionLine.hasMatch(line) &&
          (standalone.dosage.isNotEmpty ||
              _hasKnownMedicineEvidence(standalone.name) ||
              standalone.source == ScanSource.localMatch);
      if (startsMedicine || blocks.isEmpty) {
        blocks.add([line]);
      } else {
        blocks.last.add(line);
      }
    }

    final candidates = <MedicineLabelResult>[];
    for (final block in blocks) {
      final candidate = parse(block.join('\n'));
      if (candidate == null) continue;
      final existingIndex = candidates.indexWhere(
        (item) =>
            item.name.toLowerCase() == candidate.name.toLowerCase() &&
            item.dosage.toLowerCase() == candidate.dosage.toLowerCase(),
      );
      if (existingIndex < 0) {
        candidates.add(candidate);
      } else if (_hasFollowingSig(candidate) &&
          !_hasFollowingSig(candidates[existingIndex])) {
        candidates[existingIndex] = candidate;
      }
    }
    if (candidates.isEmpty) {
      final single = parse(rawText);
      if (single != null) candidates.add(single);
    }
    // Catalog-free fallback: international brands and INN names must survive
    // even when they are absent from the Philippine registry. Only accept a
    // fuzzy/catalog correction when a dosage appears on the same line or its
    // attached SIG block; the extracted OCR spelling remains authoritative.
    for (final item in _dedupePrescriptionItems(
      parsePrescriptionItems(rawText),
    )) {
      final exists = candidates.any(
        (candidate) =>
            candidate.name.toLowerCase() == item.drugName.toLowerCase() &&
            candidate.dosage.toLowerCase().replaceAll(' ', '') ==
                item.strength.toLowerCase().replaceAll(' ', ''),
      );
      if (exists) continue;
      candidates.add(
        MedicineLabelResult(
          name: item.drugName,
          dosage: item.strength,
          confidence: item.strength.isEmpty ? 0.52 : 0.72,
          nameConfidence: 0.70,
          dosageConfidence: item.strength.isEmpty ? 0 : 0.85,
          rawText: item.rawLine,
        ),
      );
    }
    return candidates;
  }

  /// Extracts every medicine-like line without consulting a national catalog.
  /// This prevents unfamiliar names such as Betaloc or Dorzolamidum from being
  /// relabeled as the nearest local brand.
  List<PrescriptionItem> parsePrescriptionItems(String rawText) {
    if (rawText.length > _maxRawTextLength) return const [];
    final normalizedText = _sanitizePackagingText(rawText);
    final lines = normalizedText
        .split(RegExp(r'[\r\n]+'))
        .map(_normalizeLine)
        .where((line) => line.isNotEmpty)
        .toList();
    final items = <PrescriptionItem>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final strengthMatch = _prescriptionStrengthPattern.firstMatch(line);
      if (strengthMatch == null) continue;
      final strength = _normalizeDosage(strengthMatch.group(0)!);
      final beforeStrength = line.substring(0, strengthMatch.start);
      if (_packagingMetadataLine.hasMatch(beforeStrength)) continue;
      var candidateName = _cleanPrescriptionName(beforeStrength);
      var precedingNameLines = <String>[];
      if (candidateName == null) {
        final preceding = <String>[];
        for (
          var previous = i - 1;
          previous >= 0 && preceding.length < 2;
          previous--
        ) {
          final priorLine = lines[previous];
          if (_prescriptionStrengthPattern.hasMatch(priorLine) ||
              _instructionLine.hasMatch(priorLine) ||
              _packagingMetadataLine.hasMatch(priorLine)) {
            break;
          }
          if (_therapeuticClassLine.hasMatch(priorLine)) continue;
          if (_cleanPrescriptionName(priorLine) == null) break;
          preceding.insert(0, priorLine);
        }
        if (preceding.isNotEmpty) {
          precedingNameLines = preceding;
          candidateName = _cleanPrescriptionName(
            [...preceding, beforeStrength].join(' '),
          );
        }
      }
      final name = _normalizePrescriptionName(candidateName);
      if (name == null) continue;
      final attached = <String>[...precedingNameLines, line];
      while (i + 1 < lines.length && _instructionLine.hasMatch(lines[i + 1])) {
        attached.add(lines[++i]);
      }
      final block = attached.join(' ');
      final quantity =
          RegExp(
            r'\b\d+\s*(?:tab|tabs|tablet|tablets|capsule|caps|cap|pill|amp)\b',
            caseSensitive: false,
          ).firstMatch(block)?.group(0) ??
          '';
      final instruction = const PrescriptionInstructionParser().parse(block);
      final frequency = instruction.isAsNeeded
          ? 'As needed'
          : instruction.frequency ??
                RegExp(
                  r'\b(?:QD|BID|TID|QID|PRN|Q4H|Q6H|Q8H|once daily|twice daily)\b',
                  caseSensitive: false,
                ).firstMatch(block)?.group(0) ??
                '';
      items.add(
        PrescriptionItem(
          drugName: name,
          strength: strength,
          quantity: quantity,
          frequency: frequency,
          rawLine: block,
        ),
      );
    }
    return items;
  }

  List<PrescriptionItem> _dedupePrescriptionItems(
    List<PrescriptionItem> items,
  ) {
    final seen = <String>{};
    return [
      for (final item in items)
        if (seen.add(
          '${item.drugName.toLowerCase()}|'
          '${item.strength.toLowerCase().replaceAll(RegExp(r'\s+'), '')}',
        ))
          item,
    ];
  }

  String? _normalizePrescriptionName(String? value) {
    if (value == null) return null;
    final compact = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final normalized = _normalizedWords(value);
    final knownProfiles = _commonMedicineProfiles.where((profile) {
      final aliases = [profile.canonicalName, ...profile.aliases];
      return aliases.any((alias) {
        final normalizedAlias = _normalizedWords(alias);
        return normalized == normalizedAlias ||
            ' $normalized '.contains(' $normalizedAlias ');
      });
    }).toList();
    if (knownProfiles.length == 1) {
      final profile = knownProfiles.single;
      final matchedAliases = <String>{
        for (final alias in [profile.canonicalName, ...profile.aliases])
          if (' $normalized '.contains(' ${_normalizedWords(alias)} '))
            _normalizedWords(alias),
      };
      // Collapse co-labeled brand + generic names to one ingredient. A lone
      // brand or Latin INN stays as printed for human review.
      if (matchedAliases.length > 1) return profile.canonicalName;
    }
    if (knownProfiles.length > 1) return value;

    const aliases = {
      'cnetidine': 'Cimetidine',
      'cmetidine': 'Cimetidine',
      'cimetidine': 'Cimetidine',
      'oxprelol': 'Oxprelol',
      '0xprelol': 'Oxprelol',
      'betaloc': 'Betaloc',
    };
    final known = aliases[compact];
    if (known != null) return known;
    return value;
  }

  String _medicineIdentity(String value) {
    final normalized = _normalizedWords(value);
    final matches = _commonMedicineProfiles.where((profile) {
      return [profile.canonicalName, ...profile.aliases].any((alias) {
        final normalizedAlias = _normalizedWords(alias);
        return normalized == normalizedAlias ||
            ' $normalized '.contains(' $normalizedAlias ');
      });
    }).toList();
    if (matches.length == 1) {
      return _normalizedWords(matches.single.canonicalName);
    }
    return normalized;
  }

  String? _cleanPrescriptionName(String text) {
    final withoutDirections = text.replaceFirst(
      RegExp(
        r'\b(?:take|give|use|apply|inhale|inject|swallow|chew|sig|po|oral|orally|by\s+mouth|topical|inh|im|iv|sc|qd|od|bid|bd|tid|tds|qid|prn|daily|nightly|every\s+\d+\s*(?:hours?|days?)|\d+\s*(?:tabs?|tablets?|caps?|capsules?|pills?)|qty|quantity|dispense)\b.*$',
        caseSensitive: false,
      ),
      '',
    );
    final cleaned = withoutDirections
        .replaceAll(
          RegExp(
            r'\b(?:analgesic|antipyretic|anti[-\s]?inflammatory|anilide)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'\b(?:rx|prescription|medication|medicine|drug|product|name)\b\s*[:#-]?',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'^\s*(?:#?\d+\s*[.)-]\s*)+'), '')
        .replaceAll(RegExp(r'^[\s\-:.)]+|[\s\-:.)]+$'), '')
        .replaceAll(RegExp(r'[^A-Za-z0-9+./ -]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.length < 3 || RegExp(r'^\d+$').hasMatch(cleaned)) return null;
    final tokens = cleaned.split(' ').where((token) {
      final lower = token.toLowerCase();
      return lower.length >= 2 &&
          !{
            'take',
            'give',
            'and',
            'then',
            'tablet',
            'tablets',
            'tab',
            'tabs',
            'capsule',
            'capsules',
            'cap',
            'caps',
            'pill',
            'pills',
            'patient',
            'doctor',
            'physician',
            'pharmacy',
            'prescriber',
            'refill',
            'refills',
            'directions',
            'quantity',
            'qty',
            'list',
            'dose',
            'strength',
            'frequency',
            'schedule',
            'date',
          }.contains(lower);
    }).toList();
    if (tokens.isEmpty) return null;
    return tokens
        .take(4)
        .map((token) => token[0].toUpperCase() + token.substring(1))
        .join(' ');
  }

  /// Combines separate OCR reads without counting a unit disagreement as a
  /// second medicine. A disagreement stays unresolved for manual entry.
  List<MedicineLabelResult> mergeReads(
    List<MedicineLabelResult> existing,
    Iterable<MedicineLabelResult> incoming,
  ) {
    final merged = [...existing];
    for (final candidate in incoming) {
      final index = merged.indexWhere((item) {
        final itemName = _medicineIdentity(item.name);
        final candidateName = _medicineIdentity(candidate.name);
        if (itemName != candidateName) {
          return false;
        }
        if (item.dosage.toLowerCase() == candidate.dosage.toLowerCase() ||
            item.dosage.isEmpty ||
            candidate.dosage.isEmpty) {
          return true;
        }
        final left = Dosage.parse(item.dosage);
        final right = Dosage.parse(candidate.dosage);
        return left?.value != null && left!.value == right?.value;
      });
      if (index < 0) {
        merged.add(candidate);
        continue;
      }
      final old = merged[index];
      if (old.strengthConflict) continue;
      final textSource = _hasFollowingSig(candidate) && !_hasFollowingSig(old)
          ? candidate
          : old;
      final canonicalName =
          _normalizePrescriptionName(textSource.name) ?? textSource.name;
      final oldDose = Dosage.parse(old.dosage);
      final newDose = Dosage.parse(candidate.dosage);
      if (old.dosage.isNotEmpty &&
          candidate.dosage.isNotEmpty &&
          oldDose?.display != newDose?.display) {
        merged[index] = MedicineLabelResult(
          name: canonicalName,
          dosage: '',
          confidence: textSource.confidence,
          nameConfidence: textSource.nameConfidence,
          dosageConfidence: 0,
          rawText: textSource.rawText,
          kind: textSource.kind,
          source: textSource.source,
          strengthConflict: true,
        );
      } else if (candidate.dosage.isNotEmpty &&
          (old.dosage.isEmpty ||
              textSource == candidate ||
              (_hasFollowingSig(candidate) == _hasFollowingSig(old) &&
                  candidate.confidence > old.confidence))) {
        merged[index] = MedicineLabelResult(
          name: canonicalName,
          dosage: candidate.dosage,
          confidence: candidate.confidence,
          nameConfidence: candidate.nameConfidence,
          dosageConfidence: candidate.dosageConfidence,
          rawText: candidate.rawText,
          kind: candidate.kind,
          source: candidate.source,
          strengthConflict: candidate.strengthConflict,
          strengthNeedsReview: candidate.strengthNeedsReview,
        );
      }
    }
    return merged;
  }

  static final RegExp _instructionLine = RegExp(
    r'^\s*(?:sig\s*[:.]?\s*)?(?:take|give|use|apply|inhale|inject|swallow|chew|po\b|oral\b|iv\b|im\b|sc\b|topical\b|\d+\s*(?:tabs?|tablets?|caps?|capsules?|pills?)\b|(?:q\s*d|o\s*d|b[.\s-]*[i1][.\s-]*d|b[.\s-]*d|t[.\s-]*[i1][.\s-]*d|t[.\s-]*d[.\s-]*s|q[.\s-]*i[.\s-]*d|p[.\s-]*r[.\s-]*n)\b|q\s*(?:4|6|8|12)\s*(?:h|hours?)\b|(?:once|twice|three times)\s+(?:a|per)\s+day\b|every\s+\d+\s*(?:hours?|days?)\b)',
    caseSensitive: false,
  );

  bool _hasFollowingSig(MedicineLabelResult candidate) {
    final raw = candidate.rawText.toLowerCase();
    final name = candidate.name.toLowerCase();
    final nameStart = raw.indexOf(name);
    if (nameStart < 0) return false;
    final afterName = raw.substring(nameStart + name.length);
    return RegExp(
      r'\b(take|give|bid|b[.\s-]*[i1][.\s-]*d|bd|tid|t[.\s-]*[i1][.\s-]*d|tds|t[.\s-]*d[.\s-]*s|od|o[.\s-]*d|qd|daily|prn|as needed|every\s+\d+\s*hours?)\b',
    ).hasMatch(afterName);
  }

  bool _isPhDrug(String name) {
    for (var brand in _philippineBrands) {
      if (name.contains(brand)) return true;
    }
    for (var known in _knownMedicineWords) {
      if (name.contains(known)) return true;
    }
    for (var common in _commonMedicineTerms) {
      if (name.contains(common)) return true;
    }
    return false;
  }

  bool _hasKnownMedicineEvidence(String name) {
    final lowerName = name.toLowerCase();
    if (_philippineBrands.any((brand) => lowerName.contains(brand))) {
      return true;
    }
    if (_knownMedicineWords.any((word) => lowerName.contains(word))) {
      return true;
    }
    return _commonMedicineTerms.any((term) => lowerName.contains(term));
  }

  double _nonMedicineScore(String fullText) {
    double score = 0;
    for (var signal in _nonMedicineSignals) {
      if (fullText.contains(signal)) {
        score += 0.12;
      }
    }
    return score;
  }

  String _normalizeLine(String line) {
    return line
        .replaceAllMapped(
          RegExp(
            r'\b(\d+)\s*(rng|rnq|mq|rnl|rn1|m1|1u|lu)\b',
            caseSensitive: false,
          ),
          (match) {
            final unit = match.group(2)!.toLowerCase();
            return '${match.group(1)}${unit.endsWith('u')
                ? 'IU'
                : unit.endsWith('l') || unit.endsWith('1')
                ? 'mL'
                : 'mg'}';
          },
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[|_]'), ' ')
        .trim();
  }

  /// Repairs OCR confusions in the context where they are safe: letters in
  /// likely names and digits/units in strength expressions. Raw text remains
  /// attached to every result for review and audit.
  String _sanitizePackagingText(String text) {
    var result = text
        .replaceAll(RegExp(r'\brn(?=[a-z])', caseSensitive: false), 'm')
        .replaceAll(RegExp(r'\b(rng|rnq|mq)\b', caseSensitive: false), 'mg')
        .replaceAll(RegExp(r'\b(rnl|rn1|m1)\b', caseSensitive: false), 'mL')
        .replaceAll(RegExp(r'\b(1u|lu)\b', caseSensitive: false), 'IU');
    result = result
        .replaceAllMapped(
          RegExp(r'(?<=\d)[oO]+(?=\d|\s*(?:mg|mL|ml)\b)'),
          (match) => '0' * match.group(0)!.length,
        )
        .replaceAllMapped(
          RegExp(r'(?<=\d)[lI]+(?=\d|\s*(?:mg|mL|ml)\b)'),
          (match) => '1' * match.group(0)!.length,
        );
    return result;
  }

  String _normalizeDosage(String value) {
    return value
        .replaceAll(',', '.')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAllMapped(
          RegExp(
            r'\b(\d+(?:\.\d+)?)\s*(mcg|mg|g|ml)\s*/\s*(\d+(?:\.\d+)?)\s*(mcg|mg|g|ml)\b',
            caseSensitive: false,
          ),
          (match) => '${match[1]} ${match[2]} / ${match[3]} ${match[4]}',
        )
        .replaceAllMapped(
          RegExp(r'\b(ml|iu)\b', caseSensitive: false),
          (match) => match.group(0)!.toLowerCase() == 'ml' ? 'mL' : 'IU',
        )
        .trim();
  }

  int _lineIndexForMatch(List<String> lines, int matchStart) {
    var cursor = 0;
    for (var i = 0; i < lines.length; i++) {
      final end = cursor + lines[i].length;
      if (matchStart <= end) return i;
      cursor = end + 1;
    }
    return lines.length - 1;
  }

  String? _extractName(
    List<String> lines,
    int lineIndex,
    String dosageLine,
    int globalMatchStart,
  ) {
    final lineStart = lines
        .take(lineIndex)
        .fold<int>(0, (sum, line) => sum + line.length + 1);
    final localMatchStart = (globalMatchStart - lineStart).clamp(
      0,
      dosageLine.length,
    );

    final beforeDose = dosageLine.substring(0, localMatchStart);
    final sameLineName = _cleanName(beforeDose);
    if (sameLineName != null) return sameLineName;

    if (lineIndex > 0) {
      final previousLineName = _cleanName(lines[lineIndex - 1]);
      if (previousLineName != null) return previousLineName;
    }

    final afterDose = dosageLine.substring(localMatchStart);
    return _cleanName(afterDose.replaceFirst(_dosagePattern, ''));
  }

  String? _cleanName(String text) {
    final withoutNoise = text
        .replaceAll(RegExp(r'[^A-Za-z0-9+\-/. ]'), ' ')
        .replaceAll(
          RegExp(r'\b(Rx|NDC|USP|BP|IP)\b', caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (withoutNoise.length < 3 || !_lettersPattern.hasMatch(withoutNoise)) {
      return null;
    }

    final nameCorrected = withoutNoise
        .replaceAll(RegExp(r'rn', caseSensitive: false), 'm')
        .replaceAll('0', 'O');
    final tokens = nameCorrected
        .split(' ')
        .where((token) => _nameTokenPattern.hasMatch(token))
        .where((token) => !_nameStopWords.contains(token.toLowerCase()))
        .where((token) => !RegExp(r'^\d+$').hasMatch(token))
        .toList();

    if (tokens.isEmpty) return null;

    final usefulTokens = <String>[];
    for (final token in tokens) {
      if (_dosagePattern.hasMatch(token)) break;
      usefulTokens.add(token);
      if (usefulTokens.length == 4) break;
    }

    final name = usefulTokens.join(' ').trim();
    if (name.length < 3 || name.length > 60) return null;
    return _titleCaseKnownInput(name);
  }

  String _titleCaseKnownInput(String text) {
    return text
        .split(' ')
        .map((word) {
          if (word.length <= 3 && word == word.toUpperCase()) return word;
          return word[0].toUpperCase() + word.substring(1);
        })
        .join(' ');
  }

  ({double overall, double name, double dosage}) _scoreCandidate({
    required String name,
    required String dosage,
    required String line,
    required String fullText,
    required double dictionaryConfidence,
  }) {
    var score = 0.45;
    final lowerLine = line.toLowerCase();
    final lowerName = name.toLowerCase();

    if (dosage.isNotEmpty) {
      score += 0.18;
    }
    if (_medicineSignals.any((signal) => fullText.contains(signal))) {
      score += 0.18;
    }
    if (_medicineSignals.any((signal) => lowerLine.contains(signal))) {
      score += 0.08;
    }
    if (_knownMedicineWords.any((word) => lowerName.contains(word))) {
      score += 0.22;
    }
    if (_philippineBrands.any((brand) => lowerName.contains(brand))) {
      score += 0.28;
    }
    if (_philippineBrands.any((brand) => fullText.contains(brand))) {
      score += 0.10;
    }
    if (_commonMedicineTerms.any((term) => lowerName.contains(term))) {
      score += 0.16;
    }
    if (dictionaryConfidence >= 0.78) {
      score += 0.14;
    }
    if (RegExp(
      r'\b(hcl|hydrochloride|sodium|potassium|calcium)\b',
    ).hasMatch(lowerLine)) {
      score += 0.05;
    }
    if (name.split(' ').length > 1) {
      score += 0.04;
    }
    if (RegExp(
      r'\b(price|sale|discount|calories|nutrition|battery|charger)\b',
    ).hasMatch(fullText)) {
      score -= 0.18;
    }

    return (
      overall: score.clamp(0, 1),
      name: _nameConfidence(name, lowerName, line, fullText),
      dosage: _dosageConfidence(dosage),
    );
  }

  _DictionaryMatch? _findCommonMedicineMatch(
    String text, {
    String? likelyName,
  }) {
    final haystack = _normalizedWords('$likelyName $text');
    final tokens = RegExp(r'[a-z0-9]+')
        .allMatches(haystack)
        .map((match) => match.group(0)!)
        .where((token) => token.length >= 4)
        .toList();

    _DictionaryMatch? best;
    for (final profile in _commonMedicineProfiles) {
      final aliases = [profile.canonicalName, ...profile.aliases];
      for (final alias in aliases) {
        final aliasWords = _normalizedWords(alias);
        final aliasCompact = _compact(alias);
        double confidence = 0;

        if (aliasWords.length >= 4 &&
            RegExp(
              '(^| )${RegExp.escape(aliasWords)}( |\$)',
            ).hasMatch(haystack)) {
          confidence = 0.96;
        } else if (aliasCompact.length >= 6) {
          for (final token in tokens) {
            final tokenScore = _tokenSimilarity(token, aliasCompact);
            if (tokenScore > confidence) confidence = tokenScore;
          }
        }

        if (confidence > 0 && (best == null || confidence > best.confidence)) {
          best = _DictionaryMatch(profile, confidence);
        }
      }
    }

    return best;
  }

  double _tokenSimilarity(String token, String aliasCompact) {
    if (token == aliasCompact) return 0.96;
    if (token.length < 5 || aliasCompact.length < 6) return 0;

    final commonPrefix = _commonPrefixLength(token, aliasCompact);
    var score = 0.0;
    if (commonPrefix >= 4) {
      score = 0.68 + (commonPrefix.clamp(0, 8) * 0.025);
      if (token.length >= aliasCompact.length) score += 0.04;
    }

    final lengthGap = (token.length - aliasCompact.length).abs();
    if (lengthGap <= 3) {
      final distance = _boundedEditDistance(token, aliasCompact, 3);
      if (distance <= 3) {
        final editScore = 0.92 - (distance * 0.08);
        if (editScore > score) score = editScore;
      }
    }

    return score.clamp(0.0, 0.92);
  }

  int _commonPrefixLength(String a, String b) {
    final max = a.length < b.length ? a.length : b.length;
    var i = 0;
    while (i < max && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  int _boundedEditDistance(String a, String b, int maxDistance) {
    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0);
      current[0] = i;
      var rowMin = current[0];
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        final value = [
          previous[j] + 1,
          current[j - 1] + 1,
          previous[j - 1] + cost,
        ].reduce((left, right) => left < right ? left : right);
        current[j] = value;
        if (value < rowMin) rowMin = value;
      }
      if (rowMin > maxDistance) return maxDistance + 1;
      previous = current;
    }
    return previous[b.length];
  }

  String _normalizedWords(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _compact(String text) {
    return text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  /// Field-level confidence for the medicine name, so the scan flow can say
  /// whether the name itself is reliable even when the dose is not.
  double _nameConfidence(
    String name,
    String lowerName,
    String line,
    String fullText,
  ) {
    var c = 0.45;
    if (_knownMedicineWords.any((word) => lowerName.contains(word))) {
      c += 0.22;
    }
    if (_philippineBrands.any((brand) => lowerName.contains(brand))) {
      c += 0.28;
    }
    if (_medicineSignals.any((signal) => fullText.contains(signal))) {
      c += 0.12;
    }
    if (_medicineSignals.any((signal) => line.toLowerCase().contains(signal))) {
      c += 0.06;
    }
    if (name.split(' ').length > 1) {
      c += 0.05;
    }
    return c.clamp(0.0, 1.0);
  }

  /// Field-level confidence for the dosage. A recognized unit and a strength
  /// expression push it up; a bare number leaves it low so the scan flow can
  /// ask the user to pick the real dose.
  double _dosageConfidence(String dosage) {
    if (dosage.isEmpty) return 0.0;
    var c = 0.4;
    if (RegExp(
      r'\b(mcg|mg|g|ml|mL|iu|IU|units?|%|drop|drops|puff|puffs|tablet|tablets|capsule|capsules)\b',
    ).hasMatch(dosage)) {
      c += 0.25;
    }
    if (RegExp(r'/\s*\d').hasMatch(dosage)) {
      c += 0.2;
    }
    if (RegExp(r'\b\d+(?:[.,]\d+)?\b').hasMatch(dosage)) {
      c += 0.15;
    }
    return c.clamp(0.0, 1.0);
  }
}

class _CommonMedicineProfile {
  final String canonicalName;
  final List<String> aliases;

  const _CommonMedicineProfile(this.canonicalName, this.aliases);
}

class _DictionaryMatch {
  final _CommonMedicineProfile profile;
  final double confidence;

  const _DictionaryMatch(this.profile, this.confidence);
}

class _Candidate {
  final String name;
  final String dosage;
  final double confidence;
  final double nameConfidence;
  final double dosageConfidence;

  const _Candidate(
    this.name,
    this.dosage,
    this.confidence,
    this.nameConfidence,
    this.dosageConfidence,
  );
}
