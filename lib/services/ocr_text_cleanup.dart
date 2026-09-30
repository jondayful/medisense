/// Conservative, local cleanup for OCR output before it reaches the label
/// parser. It deliberately corrects only known medicine words and patterns
/// whose context makes character swaps unambiguous; uncertain reads remain
/// unchanged for the confirmation UI.
class OcrTextCleanup {
  const OcrTextCleanup({this.dictionary = _defaultDictionary});

  final Set<String> dictionary;

  /// Joins line-break hyphenation only when the result is a known medicine.
  /// This corrects reads such as `Parace-tamol` without changing ordinary
  /// compound words such as `long-term`.
  String joinKnownHyphenatedMedicineWords(String source) =>
      source.replaceAllMapped(RegExp(r'\b([A-Za-z]{2,})-\s*([A-Za-z]{2,})\b'), (
        match,
      ) {
        final joined = '${match[1]}${match[2]}';
        return dictionary.contains(joined.toLowerCase()) ? joined : match[0]!;
      });

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
    var text = joinKnownHyphenatedMedicineWords(source).replaceAllMapped(
      RegExp(r'([A-Za-z]{3,})[ \t]*\r?\n[ \t]*([A-Za-z]{1,3})\b'),
      (match) {
        final joined = '${match[1]}${match[2]}';
        return dictionary.contains(joined.toLowerCase()) ? joined : match[0]!;
      },
    );
    text = text
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

    text = text
        .replaceAllMapped(
          RegExp(
            r'\b[sS5][oO0]{2}\b(?=\s*(?:mg|mcg|meg|mog|ug|uq)\b)',
            caseSensitive: false,
          ),
          (_) => '500',
        )
        .replaceAllMapped(
          RegExp(
            r'\b(\d+(?:\.\d+)?)\s*(?:mog|meg|ug|uq)\b',
            caseSensitive: false,
          ),
          (match) => '${match[1]} mcg',
        )
        .replaceAllMapped(
          RegExp(
            r'\b(\d+(?:\.\d+)?)\s*(mcg|mg|g|ml)\s*/\s*(\d+(?:\.\d+)?)\s*(mcg|mg|g|ml)\b',
            caseSensitive: false,
          ),
          (match) {
            String unit(String value) =>
                value.toLowerCase() == 'ml' ? 'mL' : value.toLowerCase();
            return '${match[1]}${unit(match[2]!)}/${match[3]}${unit(match[4]!)}';
          },
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
    return OcrCleanupResult(
      text: stripPackagingNoise(text),
      corrections: corrections,
    );
  }

  /// Removes label boilerplate line by line so a stamp cannot consume the
  /// medicine on the following line. Strengths and ingredient separators stay.
  String stripPackagingNoise(String source) {
    return source
        .split('\n')
        .map((line) {
          var value = line;
          if (RegExp(
            r'^\s*(?:batch|lot|bkn|bn|paf|exp|mfg|md|drp[- ]?\d+)\b',
            caseSensitive: false,
          ).hasMatch(value)) {
            return '';
          }
          value = value.replaceAll(
            RegExp(
              r'\b(?:non[- ]?steroidal(?:\s+anti[- ]?inflammatory)?(?:\s+drug)?|anti[- ]?(?:inflammatory|hflammatory)|[a-z]*[hf]lammatory|ennntary|nsaid|nsad|anti[- ]?fibrinolytic|bronchodilator|anti[- ]?hypertensive|analgesic|antipyretic|anilide|antibiotic|antihistamine)\b',
              caseSensitive: false,
            ),
            ' ',
          );
          value = value.replaceAll(
            RegExp(
              r'\b(?:(?:solution|solut[io0]n)\s+for\s+(?:inhalation|boalation|nalation)|for\s+inhalation|inhalation\s+solution|oral\s+suspension|solut[io0]n|inhalat[io0]n|boalat[io0]n|nalat[io0]n|suspension|syrup|drops|elixir|ointment|cream)\b',
              caseSensitive: false,
            ),
            ' ',
          );
          if (!RegExp(
            r'^\s*(?:take|give|use|apply|inhale|inject|swallow|chew|\d+\s*(?:tabs?|caps?|tablets?|capsules?|pills?))\b',
            caseSensitive: false,
          ).hasMatch(value)) {
            value = value.replaceAll(
              RegExp(
                r'\b(?:capsules?|tablets?|caps?|tabs?|nebules?|ampoules?|vials?|pills?)\b',
                caseSensitive: false,
              ),
              ' ',
            );
          }
          value = value.replaceAll(
            RegExp(
              r'\b(?:rx\s+only|batch|lot|bkn|bn|paf|exp|ed|md|mfg|dr\.?\s*xy\d+|rx)\b(?:\s*[:#]?\s*(?:[A-Z]?\d+[A-Z0-9/-]*|\d{2}/\d{4}))?',
              caseSensitive: false,
            ),
            ' ',
          );
          value = value.replaceAll(RegExp(r'\b\d{2}/\d{4}\b'), ' ');
          value = value.replaceFirst(
            RegExp(r'^\s*reading\b\s*', caseSensitive: false),
            '',
          );
          return value.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
        })
        .join('\n');
  }

  /// Catalog lookup may use a Latin INN spelling; preserve the printed name
  /// in the OCR result and apply this only to a lookup key.
  String normalizeInnForLookup(String name) => name
      .replaceAllMapped(RegExp(r'idum\b', caseSensitive: false), (_) => 'ide')
      .replaceAllMapped(RegExp(r'um\b', caseSensitive: false), (_) => '');

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
