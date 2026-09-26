/// A medication dose: a value with an explicit unit, parsed from a dosage
/// string without ever stripping or converting units.
///
/// Safety contract: `parse` never clamps and never guesses a unit. When the
/// unit is missing it stays `null` and the raw text is preserved so the UI
/// can make the user choose instead of silently defaulting to `mg`.
class Dosage {
  /// The numeric amount, or null when the string is not a clean dosage.
  final double? value;

  /// The unit (`mL`, `mg`, `units`, ...), or null when ambiguous.
  final String? unit;

  /// The label's own strength expression (e.g. `100 mg / 5 mL`), kept whole.
  final String? strength;

  /// The second half of a strength expression — e.g. for `100 mg / 5 mL`,
  /// [secondValue] is 5 and [secondUnit] is `mL`. Null for simple doses.
  final double? secondValue;
  final String? secondUnit;

  /// The original text as it was scanned or typed.
  final String raw;

  const Dosage({
    required this.value,
    required this.unit,
    required this.strength,
    required this.raw,
    this.secondValue,
    this.secondUnit,
  });

  bool get hasStrength => strength != null && strength!.isNotEmpty;

  /// True when we could not confirm what a single dose is — the value or the
  /// unit is unknown. Callers must surface this, never guess.
  bool get isAmbiguous => value == null || unit == null;

  /// The canonical display string, e.g. `5 mL`, `10 units`, `100 mg / 5 mL`.
  /// When ambiguous, falls back to the raw text verbatim.
  String get display {
    if (strength != null && strength!.isNotEmpty) return strength!;
    if (value != null && unit != null) {
      return '${formatNumber(value!)} $unit';
    }
    return raw.isEmpty ? '?' : raw;
  }

  static const List<String> kUnits = [
    'mL',
    'mg',
    'mcg',
    'g',
    'units',
    'drops',
    'puffs',
    'tablet',
    'capsule',
    '%',
  ];

  static String formatNumber(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  static final RegExp _strengthPattern = RegExp(
    r'(\d+(?:[.,]\d+)?)\s*([a-zA-Z%]+)\s*/\s*(\d+(?:[.,]\d+)?)\s*([a-zA-Z%]+)',
  );
  static final RegExp _simplePattern = RegExp(
    r'(\d+(?:[.,]\d+)?)\s*([a-zA-Z%]+)?',
  );

  static Dosage? parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    if (!RegExp(r'\d').hasMatch(text)) return null;

    final strength = _strengthPattern.firstMatch(text);
    if (strength != null) {
      final value = double.tryParse(strength.group(1)!.replaceAll(',', '.'));
      final unit = _normalizeUnit(strength.group(2)!);
      final d2 = double.tryParse(strength.group(3)!.replaceAll(',', '.'));
      final u2 = _normalizeUnit(strength.group(4)!);
      if (value != null && d2 != null) {
        final expression =
            '${formatNumber(value)} $unit / ${formatNumber(d2)} $u2';
        return Dosage(
          value: value,
          unit: unit,
          strength: expression,
          secondValue: d2,
          secondUnit: u2,
          raw: raw,
        );
      }
    }

    final simple = _simplePattern.firstMatch(text);
    if (simple != null) {
      final value = double.tryParse(simple.group(1)!.replaceAll(',', '.'));
      final unit =
          simple.group(2) == null ? null : _normalizeUnit(simple.group(2)!);
      return Dosage(
        value: value,
        unit: unit,
        strength: null,
        raw: raw,
      );
    }

    return Dosage(value: null, unit: null, strength: null, raw: raw);
  }

  static String _normalizeUnit(String unit) {
    switch (unit.toLowerCase().replaceAll('.', '')) {
      case 'ml':
        return 'mL';
      case 'mcg':
        return 'mcg';
      case 'mg':
        return 'mg';
      case 'g':
        return 'g';
      case 'iu':
      case 'u':
      case 'unit':
      case 'units':
        return 'units';
      case '%':
        return '%';
      case 'drop':
      case 'drops':
        return 'drops';
      case 'puff':
      case 'puffs':
        return 'puffs';
      case 'tab':
      case 'tablet':
      case 'tablets':
        return 'tablet';
      case 'cap':
      case 'capsule':
      case 'capsules':
        return 'capsule';
      default:
        return unit.toLowerCase();
    }
  }
}
