import '../models/dosage.dart';
import 'medicine_expiry_parser.dart';

/// Conservative parsing for guided voice entry. Unknown values remain null so
/// the conversation asks again instead of guessing a medication dose or date.
class VoiceMedicationInput {
  const VoiceMedicationInput._();

  static const _small = <String, int>{
    'zero': 0,
    'one': 1,
    'two': 2,
    'three': 3,
    'four': 4,
    'five': 5,
    'six': 6,
    'seven': 7,
    'eight': 8,
    'nine': 9,
    'ten': 10,
    'eleven': 11,
    'twelve': 12,
    'thirteen': 13,
    'fourteen': 14,
    'fifteen': 15,
    'sixteen': 16,
    'seventeen': 17,
    'eighteen': 18,
    'nineteen': 19,
    'twenty': 20,
    'thirty': 30,
    'forty': 40,
    'fifty': 50,
    'sixty': 60,
    'seventy': 70,
    'eighty': 80,
    'ninety': 90,
    'isa': 1,
    'isang': 1,
    'dalawa': 2,
    'tatlo': 3,
    'apat': 4,
    'lima': 5,
    'sampu': 10,
  };

  static const _units = <String, String>{
    'mg': 'mg',
    'milligram': 'mg',
    'milligrams': 'mg',
    'mcg': 'mcg',
    'microgram': 'mcg',
    'micrograms': 'mcg',
    'g': 'g',
    'gram': 'g',
    'grams': 'g',
    'ml': 'mL',
    'milliliter': 'mL',
    'milliliters': 'mL',
    'unit': 'units',
    'units': 'units',
    'drop': 'drops',
    'drops': 'drops',
    'puff': 'puffs',
    'puffs': 'puffs',
    'tablet': 'tablet',
    'tablets': 'tablet',
    'capsule': 'capsule',
    'capsules': 'capsule',
  };

  static String? dose(String transcript) {
    final normalized = transcript.toLowerCase().replaceAll('-', ' ').trim();
    final unitMatch = RegExp(
      r'\b(milligrams?|micrograms?|milliliters?|grams?|tablets?|capsules?|units?|drops?|puffs?|mcg|mg|ml|g)\b',
    ).firstMatch(normalized);
    if (unitMatch == null) return null;
    final unit = _units[unitMatch.group(1)!];
    if (unit == null) return null;
    var amountText = normalized.substring(0, unitMatch.start).trim();
    amountText = amountText
        .replaceFirst(RegExp(r'^(?:the )?(?:dose is |take |give )'), '')
        .trim();
    if (amountText.isEmpty) return null;
    final amount = double.tryParse(amountText) ?? _numberWords(amountText);
    if (amount == null || amount <= 0 || amount > 100000) return null;
    final dosage = Dosage.parse('${Dosage.formatNumber(amount)} $unit');
    return dosage == null || dosage.isAmbiguous ? null : dosage.display;
  }

  static double? _numberWords(String source) {
    final words = source.split(RegExp(r'\s+'));
    if (words.isEmpty ||
        words.any(
          (word) =>
              word != 'hundred' &&
              word != 'thousand' &&
              !_small.containsKey(word),
        )) {
      return null;
    }
    if (words.length > 1 && words.every((word) => (_small[word] ?? 99) < 10)) {
      final digits = words.map((word) => _small[word]).join();
      return double.tryParse(digits);
    }
    var total = 0;
    var group = 0;
    for (final word in words) {
      if (word == 'hundred') {
        if (group == 0) return null;
        group *= 100;
      } else if (word == 'thousand') {
        if (group == 0) return null;
        total += group * 1000;
        group = 0;
      } else {
        group += _small[word]!;
      }
    }
    return (total + group).toDouble();
  }

  static DateTime? expiry(String transcript) {
    final text = transcript.toLowerCase().trim();
    final numeric = RegExp(
      r'\b(0?[1-9]|1[0-2])\s*(?:/|slash|dash|-|\s)\s*(20\d{2}|2100)\b',
    ).firstMatch(text);
    if (numeric != null) {
      return MedicineExpiryParser.parseManual(
        '${numeric.group(1)!.padLeft(2, '0')}/${numeric.group(2)}',
      );
    }
    const months = <String, int>{
      'january': 1,
      'february': 2,
      'march': 3,
      'april': 4,
      'may': 5,
      'june': 6,
      'july': 7,
      'august': 8,
      'september': 9,
      'october': 10,
      'november': 11,
      'december': 12,
    };
    for (final entry in months.entries) {
      final match = RegExp('\\b${entry.key}\\s+(.+)\$').firstMatch(text);
      if (match == null) continue;
      final yearText = match.group(1)!.trim();
      int? year = int.tryParse(yearText);
      if (year == null && yearText.startsWith('twenty ')) {
        final remainder = yearText.substring(7);
        final last = _numberWords(remainder);
        if (last != null && last >= 0 && last <= 99) {
          year = 2000 + last.toInt();
        }
      }
      if (year == null && yearText.startsWith('two thousand ')) {
        final last = _numberWords(yearText.substring(13));
        if (last != null && last >= 0 && last <= 99) {
          year = 2000 + last.toInt();
        }
      }
      if (year == null) return null;
      return MedicineExpiryParser.parseManual(
        '${entry.value.toString().padLeft(2, '0')}/$year',
      );
    }
    return null;
  }
}
