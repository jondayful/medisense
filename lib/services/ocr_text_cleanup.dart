/// Conservative, local cleanup for OCR output before it reaches the label
/// parser. It deliberately corrects only known medicine words and patterns
/// whose context makes character swaps unambiguous; uncertain reads remain
/// unchanged for the confirmation UI.
class OcrTextCleanup {
  const OcrTextCleanup({this.dictionary = _defaultDictionary});

  final Set<String> dictionary;

  static const Set<String> _defaultDictionary = {
    'acetaminophen',
    'ambroxol',
    'amoxicillin',
    'atorvastatin',
    'azithromycin',
    'biogesic',
    'bioflu',
    'carbocisteine',
    'cetirizine',
    'clopidogrel',
    'decolgen',
    'diatabs',
    'furosemide',
    'ibuprofen',
    'kremil',
    'loperamide',
    'losartan',
    'mefenamic',
    'metformin',
    'mucosolvon',
    'neozep',
    'omeprazole',
    'paracetamol',
    'salbutamol',
    'simvastatin',
    'solmux',
    'sinecod',
    'vitamin',
    'zithromax',
    'betaloc',
    'dorzolamide',
    'dorzolamidum',
    'cimetidine',
    'oxprelol',
    'oxprenolol',
  };

  OcrCleanupResult clean(String source) {
    var text = source
        .replaceAll('\u00a0', ' ')
        .replaceAll(RegExp(r'[|]'), 'I')
        // OCR often confuses a leading capital O with zero in a drug name.
        .replaceAllMapped(RegExp(r'\b0(?=[xX][A-Za-z])'), (_) => 'O')
        // OCR frequently splits a decimal/strength around punctuation.
        .replaceAllMapped(
          RegExp(r'\b([0-9OIl])\s*[,.:]\s*([0-9OIl])\b'),
          (match) => '${_numeric(match[1]!)}.${_numeric(match[2]!)}',
        )
        .replaceAllMapped(
          RegExp(
            r'\b([0-9OIl]{1,5})\s*(m[gq]|rn[gq]|mc[gq]|I[Uu])\b',
            caseSensitive: false,
          ),
          (match) => '${_numeric(match[1]!)} ${_unit(match[2]!)}',
        );

    final corrections = <OcrCorrection>[];
    text = text.replaceAllMapped(RegExp(r"[A-Za-z][A-Za-z0-9'-]*"), (match) {
      final token = match[0]!;
      final normalized = token.toLowerCase();
      final optical = _opticalMedicineCorrection(token);
      if (optical != null) {
        corrections.add(OcrCorrection(token, optical));
        return optical;
      }
      if (dictionary.contains(normalized) || normalized.length < 5) {
        return token;
      }

      final candidate = _closestDictionaryWord(normalized);
      if (candidate == null) {
        return token;
      }
      corrections.add(OcrCorrection(token, candidate));
      return _preserveCase(token, candidate);
    });
    return OcrCleanupResult(text: text, corrections: corrections);
  }

  String? _opticalMedicineCorrection(String token) {
    final lower = token.toLowerCase();
    if (lower == 'cnetidine' || lower == 'cmetidine') {
      return _preserveCase(token, 'cimetidine');
    }
    // This observed Cetirizine OCR variant drops the narrow `ri` strokes.
    // Keep it as an exact alias instead of loosening fuzzy matching globally.
    if (lower == 'cetinzine') {
      return _preserveCase(token, 'cetirizine');
    }
    // In alphabetic words OCR commonly reads the two vertical strokes of
    // `m` as `rn`; keep the replacement scoped to word interiors.
    final corrected = token.replaceAllMapped(
      RegExp(r'(?<=[A-Za-z])rn(?=[A-Za-z])', caseSensitive: false),
      (_) => 'm',
    );
    return corrected == token ? null : corrected;
  }

  String? _closestDictionaryWord(String token) {
    // The common OCR pairs are tried before edit distance. Limiting the
    // distance makes this safe for medicine names that happen to be similar.
    final swapped = token
        .replaceAll('0', 'o')
        .replaceAll('1', 'l')
        .replaceAll('5', 's');
    if (dictionary.contains(swapped)) return swapped;

    final allowed = token.length >= 10 ? 2 : 1;
    String? best;
    var bestDistance = allowed + 1;
    for (final word in dictionary) {
      if ((word.length - token.length).abs() > allowed) continue;
      if (word[0] != token[0] && word[0] != swapped[0]) {
        continue;
      }
      final distance = _boundedLevenshtein(token, word, allowed);
      if (distance < bestDistance) {
        best = word;
        bestDistance = distance;
      }
    }
    return best;
  }

  static String _numeric(String value) =>
      value.replaceAll(RegExp('[Oo]'), '0').replaceAll(RegExp('[Il]'), '1');

  static String _unit(String value) {
    final normalized = value
        .toLowerCase()
        .replaceAll('q', 'g')
        .replaceAll('rn', 'm');
    return normalized == 'iu' ? 'IU' : normalized;
  }

  static String _preserveCase(String original, String replacement) =>
      original == original.toUpperCase()
      ? replacement.toUpperCase()
      : original.isNotEmpty && original[0] == original[0].toUpperCase()
      ? '${replacement[0].toUpperCase()}${replacement.substring(1)}'
      : replacement;

  static int _boundedLevenshtein(String a, String b, int maxDistance) {
    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0)..[0] = i;
      var minimum = i;
      for (var j = 1; j <= b.length; j++) {
        final value = [
          previous[j] + 1,
          current[j - 1] + 1,
          previous[j - 1] +
              (a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1),
        ].reduce((left, right) => left < right ? left : right);
        current[j] = value;
        if (value < minimum) minimum = value;
      }
      if (minimum > maxDistance) return maxDistance + 1;
      previous = current;
    }
    return previous[b.length];
  }
}

class OcrCleanupResult {
  const OcrCleanupResult({required this.text, required this.corrections});
  final String text;
  final List<OcrCorrection> corrections;
}

class OcrCorrection {
  const OcrCorrection(this.from, this.to);
  final String from;
  final String to;
}
