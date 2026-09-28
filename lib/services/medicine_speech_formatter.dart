import 'ph_drug_catalog.dart';
import 'ocr_text_cleanup.dart';

/// Converts OCR/database medicine fields into short, natural speech.
///
/// Package labels may include legal marks, or print both a product brand and
/// its generic ingredient. The latter is one medicine, not two medicines.
class MedicineSpeechFormatter {
  static final _legalMarks = RegExp(r'[\u00a9\u00ae\u2122\u2120]');
  static final _legalWords = RegExp(
    r'\b(?:copyright|trademark|registered|registration mark)\b',
    caseSensitive: false,
  );
  static final _dosage = RegExp(
    r'\d+(?:[.,]\d+)?\s*(?:mcg|mg|g|ml|iu|units?|%|drops?|puffs?)',
    caseSensitive: false,
  );

  // Fallbacks used before the catalog is ready and for packaging OCR that
  // joins a known brand and ingredient on one line.
  static const _brandGenericPairs = <String, String>{
    'biogesic': 'paracetamol|acetaminophen',
    'panadol': 'paracetamol|acetaminophen',
    'tylenol': 'paracetamol|acetaminophen',
    'calpol': 'paracetamol|acetaminophen',
    'advil': 'ibuprofen',
    'medicol': 'ibuprofen',
    'amoxil': 'amoxicillin',
    'ponstan': 'mefenamic acid',
    'buscopan': 'hyoscine|scopolamine',
    'glucophage': 'metformin',
    'zithromax': 'azithromycin',
  };

  const MedicineSpeechFormatter._();

  static String medicineName(String value) {
    final cleaned = _clean(
      const OcrTextCleanup().joinKnownHyphenatedMedicineWords(value),
    );
    if (cleaned.isEmpty) return '';

    // The catalog tells us when OCR matched a registered brand. Prefer it so
    // a product brand and its generic ingredient are never spoken twice.
    final catalogMatch = PhDrugCatalog.instance.findBest(cleaned);
    if (catalogMatch?.matchedBrand == true &&
        catalogMatch!.product.brandName.isNotEmpty) {
      return _clean(catalogMatch.product.brandName);
    }

    final normalized = cleaned.toLowerCase();
    for (final pair in _brandGenericPairs.entries) {
      final brand = RegExp('\\b${RegExp.escape(pair.key)}\\b');
      final generic = RegExp('\\b(?:${pair.value})\\b');
      if (brand.hasMatch(normalized) && generic.hasMatch(normalized)) {
        return pair.key[0].toUpperCase() + pair.key.substring(1);
      }
    }
    return cleaned;
  }

  /// Returns only strength-like parts, for example `500 mg` or `100 mg / 5 mL`.
  /// If OCR did not produce a recognizable strength, the cleaned source is
  /// retained so a user-entered dosage is not silently lost.
  static String strength(String value) {
    final cleaned = _clean(value);
    if (cleaned.isEmpty) return '';
    final matches = _dosage
        .allMatches(cleaned)
        .map((m) => m.group(0)!)
        .toList();
    return matches.isEmpty ? cleaned : matches.join(' / ');
  }

  static String _clean(String value) => value
      .replaceAll(_legalMarks, ' ')
      .replaceAll(_legalWords, ' ')
      .replaceAll(RegExp(r'[|\u2022\u00b7]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'^[,;:/\-]+|[,;:/\-]+$'), '');
}
