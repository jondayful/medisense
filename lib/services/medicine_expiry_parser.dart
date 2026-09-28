/// Parses an expiration date only when OCR captured an explicit expiry label.
/// This prevents lot and manufacturing dates from being mistaken for expiry.
class MedicineExpiryInfo {
  const MedicineExpiryInfo(this.date, {required this.hasDay});

  final DateTime date;
  final bool hasDay;

  /// A month-only expiry remains valid through the final second of that month.
  DateTime get effectiveExpirationDate => hasDay
      ? DateTime(date.year, date.month, date.day, 23, 59, 59)
      : DateTime(date.year, date.month + 1, 0, 23, 59, 59);

  bool get isExpired => effectiveExpirationDate.isBefore(DateTime.now());
}

class MedicineExpiryScanCandidate {
  const MedicineExpiryScanCandidate({
    required this.info,
    required this.recognizedText,
    required this.hasExpiryLabel,
  });

  final MedicineExpiryInfo info;
  final String recognizedText;
  final bool hasExpiryLabel;
}

class MedicineExpiryParser {
  /// Manual entry is intentionally unambiguous and stricter than OCR input.
  static DateTime? parseManual(String value) {
    if (!RegExp(r'^\d{2}/\d{4}$').hasMatch(value)) return null;
    final month = int.parse(value.substring(0, 2));
    final year = int.parse(value.substring(3, 7));
    if (year < 2000 || year > 2100 || month < 1 || month > 12) return null;
    return DateTime(year, month + 1, 0, 23, 59, 59);
  }

  /// Keep an exact day when the package provided one; month-only dates use
  /// the final day of that month in storage.
  static String formatStored(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final year = date.year.toString().padLeft(4, '0');
    final endOfMonth = DateTime(date.year, date.month + 1, 0).day;
    if (date.day == endOfMonth) return '$month/$year';
    return '$month/${date.day.toString().padLeft(2, '0')}/$year';
  }

  static final RegExp _anchor = RegExp(
    r'\b(?:exp(?:iration|iry)?|expires?|use\s*by|best\s*before)(?:[\s.:_-]*date)?\b',
    caseSensitive: false,
  );
  static final RegExp _nonExpiryLabel = RegExp(
    r'\b(?:lot|batch|mfg|mfd|manufactur(?:ed|ing|e)?|prod(?:uced|uction)?|packed|packing)\b',
    caseSensitive: false,
  );
  static final RegExp _isolatedMonthYear = RegExp(
    r'^(?:[A-Z]{3,9}[\s./-]+\d{2,4}|\d{2,4}[\s./-]+[A-Z]{3,9}|\d{1,4}[\s./-]+\d{1,4}|\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4})$',
    caseSensitive: false,
  );
  static final RegExp _numericDate = RegExp(
    r'^(?:(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4})|(\d{4})[/.\-](\d{1,2})(?:[/.\-](\d{1,2}))?|(\d{1,2})[/.\-](\d{2,4}))',
  );
  static final RegExp _namedDate = RegExp(
    r'^(?:([0-9OBS]{1,2})[\s/.\-]+([A-Z]{3,9})[\s/.\-]+([0-9OBS]{2,4})|([A-Z]{3,9})[\s/.\-]+([0-9OBS]{2,4}))',
    caseSensitive: false,
  );
  static const Map<String, int> _months = {
    'JAN': 1,
    'FEB': 2,
    'MAR': 3,
    'APR': 4,
    'MAY': 5,
    'MAI': 5,
    'JUN': 6,
    'JUL': 7,
    'AUG': 8,
    'SEP': 9,
    'SEPT': 9,
    'OCT': 10,
    'NOV': 11,
    'DEC': 12,
  };

  const MedicineExpiryParser._();

  /// The dedicated date camera may read an isolated month/year even when the
  /// package has no EXP label. The general label parser remains label-only.
  /// The caller must show each candidate for human confirmation.
  static List<MedicineExpiryScanCandidate> scanCandidates(String source) {
    final labelled = parse(source);
    if (labelled != null) {
      return [
        MedicineExpiryScanCandidate(
          info: labelled,
          recognizedText: format(labelled),
          hasExpiryLabel: true,
        ),
      ];
    }

    final candidates = <MedicineExpiryScanCandidate>[];
    final seen = <String>{};
    var previousLineWasNonExpiryLabel = false;
    for (final sourceLine in source.split(RegExp(r'[\r\n]+'))) {
      final line = sourceLine.trim().replaceAll(
        RegExp(r'^[\s:;#=._-]+|[\s:;#=._-]+$'),
        '',
      );
      if (line.isEmpty) continue;
      final isNonExpiryLine = _nonExpiryLabel.hasMatch(line);
      if (isNonExpiryLine) {
        previousLineWasNonExpiryLabel = true;
        continue;
      }
      if (_isolatedMonthYear.hasMatch(line) && !previousLineWasNonExpiryLabel) {
        var dateText = line.toUpperCase();
        final yearFirstNamed = RegExp(
          r'^(\d{2,4})[\s./-]+([A-Z]{3,9})$',
        ).firstMatch(dateText);
        if (yearFirstNamed != null) {
          dateText = '${yearFirstNamed.group(2)} ${yearFirstNamed.group(1)}';
        } else if (RegExp(r'^\d{1,4}\s+\d{1,4}$').hasMatch(dateText)) {
          dateText = dateText.replaceFirst(RegExp(r'\s+'), '/');
        }
        final info = parse('EXP $dateText');
        if (info != null && seen.add(format(info))) {
          candidates.add(
            MedicineExpiryScanCandidate(
              info: info,
              recognizedText: line,
              hasExpiryLabel: false,
            ),
          );
        }
      }
      previousLineWasNonExpiryLabel = false;
    }
    return candidates;
  }

  static MedicineExpiryInfo? parse(String source) {
    final anchor = _anchor.firstMatch(source);
    if (anchor == null) return null;
    // Limit typo repair to the short date field following an expiry anchor;
    // never rewrite the medicine name or unrelated package text.
    final tail = source.substring(anchor.end).trimLeft();
    final rawCandidate = tail
        .replaceFirst(RegExp(r'^[\s:;#=._-]+'), '')
        .split(RegExp(r'[\r\n]'))
        .first
        .trim()
        .toUpperCase();

    final named = _namedDate.firstMatch(rawCandidate);
    if (named != null) {
      int? parseDateDigits(String? value) => int.tryParse(
        (value ?? '')
            .replaceAll('O', '0')
            .replaceAll('B', '8')
            .replaceAll('S', '5'),
      );
      final day = parseDateDigits(named.group(1));
      final monthToken = (named.group(2) ?? named.group(4) ?? '').substring(
        0,
        3,
      );
      final year = _yearDigits(
        named.group(3) ?? named.group(5),
        parseDateDigits,
      );
      final month = _months[monthToken];
      if (month == null || year == null) return null;
      return _build(year, month, day);
    }

    final numericCandidate = rawCandidate
        .replaceAll('O', '0')
        .replaceAll('B', '8')
        .replaceAll('S', '5');
    final numeric = _numericDate.firstMatch(numericCandidate);
    if (numeric == null) return null;
    int? year;
    int? month;
    int? day;
    if (numeric.group(1) != null) {
      // Numeric day/month order is ambiguous when both values are <= 12.
      // Philippine packaging commonly prints DD/MM/YYYY; retain the legacy
      // month-first interpretation only when the first field cannot be a day.
      final first = int.tryParse(numeric.group(1)!);
      final second = int.tryParse(numeric.group(2)!);
      year = _year(numeric.group(3));
      if (first == null || second == null) return null;
      if (first > 12) {
        day = first;
        month = second;
      } else {
        month = first;
        day = second;
      }
    } else if (numeric.group(4) != null) {
      year = int.tryParse(numeric.group(4)!);
      month = int.tryParse(numeric.group(5)!);
      day = int.tryParse(numeric.group(6) ?? '');
    } else {
      final first = int.tryParse(numeric.group(7)!);
      final second = int.tryParse(numeric.group(8)!);
      if (first != null &&
          first > 12 &&
          first < 100 &&
          second != null &&
          second <= 12) {
        year = _year(numeric.group(7));
        month = second;
      } else {
        month = first;
        year = _year(numeric.group(8));
      }
    }
    if (year == null || month == null) return null;
    return _build(year, month, day);
  }

  static MedicineExpiryInfo? _build(int year, int month, int? day) {
    if (year < 2000 || year > 2100 || month < 1 || month > 12) return null;
    if (day != null && (day < 1 || day > 31)) return null;
    final date = DateTime(year, month, day ?? 1);
    if (date.year != year ||
        date.month != month ||
        (day != null && date.day != day)) {
      return null;
    }
    return MedicineExpiryInfo(date, hasDay: day != null);
  }

  static int? _year(String? value) {
    final year = int.tryParse(value ?? '');
    if (year == null) return null;
    return year < 100 ? year + 2000 : year;
  }

  static int? _yearDigits(String? value, int? Function(String?) parseDigits) {
    final year = parseDigits(value);
    return year == null ? null : (year < 100 ? year + 2000 : year);
  }

  static String format(MedicineExpiryInfo info) {
    return info.hasDay
        ? '${info.date.month.toString().padLeft(2, '0')}/${info.date.day.toString().padLeft(2, '0')}/${info.date.year}'
        : '${info.date.month.toString().padLeft(2, '0')}/${info.date.year}';
  }
}
