import '../models/medication.dart';

/// A deliberately conservative interpretation of a typed prescription SIG.
/// Missing or conflicting fields are left null: callers must ask a person,
/// never guess a dose or a refill date.
class PrescriptionInstruction {
  final double? unitsPerDose;
  final String? doseUnit;
  final String? frequency;
  final int? quantityDispensed;
  final bool isAsNeeded;

  const PrescriptionInstruction({
    this.unitsPerDose,
    this.doseUnit,
    this.frequency,
    this.quantityDispensed,
    this.isAsNeeded = false,
  });

  bool get hasSafeDailySchedule => frequency != null && !isAsNeeded;

  int? get dosesPerDay => switch (frequency) {
    'Once a day' => 1,
    'Twice a day' || 'Every 12 hours' => 2,
    'Three times a day' || 'Every 8 hours' => 3,
    'Every 6 hours' => 4,
    'Every 4 hours' => 6,
    _ => null,
  };

  /// A days-supply estimate is valid only for a fixed schedule and a whole
  /// number of tablets/capsules per administration.
  int? estimatedDaysSupply() {
    if (!hasSafeDailySchedule ||
        quantityDispensed == null ||
        unitsPerDose == null ||
        unitsPerDose! <= 0 ||
        dosesPerDay == null) {
      return null;
    }
    final dailyUnits = unitsPerDose! * dosesPerDay!;
    if (dailyUnits <= 0) return null;
    return (quantityDispensed! / dailyUnits).floor();
  }
}

class PrescriptionInstructionParser {
  const PrescriptionInstructionParser();

  PrescriptionInstruction parse(String source) {
    final text = source.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    final prn = RegExp(r'\b(prn|as needed|when needed)\b').hasMatch(text);
    // OCR engines often insert spaces/dots into short SIG abbreviations
    // ("T I D", "T.I.D.") or confuse the I with a 1 ("T1D"). Canonicalize
    // only these well-known frequency tokens; do not infer a dose or strength.
    final sigText = text
        .replaceAll(RegExp(r'\bt[\s.\-]*[i1][\s.\-]*d\b'), 'tid')
        .replaceAll(RegExp(r'\bt[\s.\-]*d[\s.\-]*s\b'), 'tds')
        .replaceAll(RegExp(r'\bb[\s.\-]*[i1][\s.\-]*d\b'), 'bid')
        .replaceAll(RegExp(r'\bb[\s.\-]*d\b'), 'bd')
        .replaceAll(RegExp(r'\bo[\s.\-]*d\b'), 'od')
        .replaceAll(RegExp(r'\bq[\s.\-]*d\b'), 'qd')
        .replaceAll(RegExp(r'\bq[\s.\-]*i[\s.\-]*d\b'), 'qid')
        .replaceAll(RegExp(r'\bp[\s.\-]*r[\s.\-]*n\b'), 'prn')
        .replaceAll(RegExp(r'\bp[\s.\-]*o\b'), 'po')
        .replaceAll(RegExp(r'\ba[\s.\-]*c\b'), 'ac')
        .replaceAll(RegExp(r'\bp[\s.\-]*c\b'), 'pc')
        .replaceAll(RegExp(r'\bh[\s.\-]*s\b'), 'hs');
    final dose = RegExp(
      r'\b(?:(?:take|give)\s+)?(\d+(?:\.\d+)?)\s*(tablets?|tabs?|capsules?|caps?|puffs?|drops?)\b',
    ).firstMatch(text);
    final explicitQty = RegExp(
      r'\b(?:qty|quantity|dispense|#)\s*[:.]?\s*(\d+)\b',
    ).firstMatch(text);
    final packageQtyMatches =
        RegExp(
          r'\b(\d+)\s*(?:tablets?|tabs?|capsules?)\b',
        ).allMatches(text).where((match) {
          final doseStart = dose?.start;
          final doseEnd = dose?.end;
          final isDoseCount =
              doseStart != null &&
              doseEnd != null &&
              match.start >= doseStart &&
              match.end <= doseEnd;
          return !isDoseCount;
        }).toList();
    final qty =
        explicitQty ??
        (packageQtyMatches.isEmpty ? null : packageQtyMatches.last);

    String? frequency;
    if (!prn) {
      if (RegExp(
        r'\b(qid|q\.i\.d\.?|four times (?:a |per )?day|4 times (?:a |per )?day)\b',
      ).hasMatch(sigText)) {
        frequency = 'Four times a day';
      } else if (RegExp(
        r'\b(bid|b\.i\.d\.?|bd|b\.d\.?|twice (?:a |per )?day|2 times (?:a |per )?day)\b',
      ).hasMatch(sigText)) {
        frequency = 'Twice a day';
      } else if (RegExp(
        r'\b(tid|t\.i\.d\.?|tds|t\.d\.s\.?|three times (?:a |per )?day|3 times (?:a |per )?day)\b',
      ).hasMatch(sigText)) {
        frequency = 'Three times a day';
      } else if (RegExp(
        r'\b(once (?:a |per )?day|daily|od|o\.d\.?|qd|q\.d\.?)\b',
      ).hasMatch(sigText)) {
        frequency = 'Once a day';
      } else {
        final hours = RegExp(
          r'\b(?:every|q)\s*(4|6|8|12)\s*(?:hours?|h)?\b',
        ).firstMatch(sigText);
        if (hours != null) frequency = 'Every ${hours.group(1)} hours';
      }
    }
    return PrescriptionInstruction(
      unitsPerDose: double.tryParse(dose?.group(1) ?? ''),
      doseUnit: dose?.group(2),
      frequency: frequency,
      quantityDispensed: int.tryParse(qty?.group(1) ?? ''),
      isAsNeeded: prn,
    );
  }
}

enum PrescriptionScanVerdict {
  matchesPlan,
  strengthMismatch,
  notInPlan,
  unclear,
}

class PrescriptionScanCheck {
  final PrescriptionScanVerdict verdict;
  final Medication? medication;
  const PrescriptionScanCheck(this.verdict, [this.medication]);
  bool get mayConfirmDose => verdict == PrescriptionScanVerdict.matchesPlan;
}

/// Local-only comparison. It intentionally never identifies an unknown scan as
/// a substitute medicine and never recommends taking a mismatched strength.
class PrescriptionSafety {
  /// Finds an existing entry with the same medicine and printed strength.
  /// This is also used when a scan reaches the edit form after OCR review.
  static Medication? findMatchingMedication({
    required String scannedName,
    required String scannedStrength,
    required List<Medication> activeMedications,
  }) {
    final name = _normalise(scannedName);
    final strength = _normaliseStrength(scannedStrength);
    if (name.isEmpty || strength.isEmpty) return null;
    for (final medication in activeMedications) {
      if (_normalise(medication.name) == name &&
          _normaliseStrength(medication.dosage) == strength) {
        return medication;
      }
    }
    return null;
  }

  static PrescriptionScanCheck check({
    required String scannedName,
    required String scannedStrength,
    required List<Medication> activeMedications,
  }) {
    final name = _normalise(scannedName);
    if (name.isEmpty) {
      return const PrescriptionScanCheck(PrescriptionScanVerdict.unclear);
    }
    final sameName = activeMedications
        .where((m) => _normalise(m.name) == name)
        .toList();
    if (sameName.isEmpty) {
      return const PrescriptionScanCheck(PrescriptionScanVerdict.notInPlan);
    }
    if (scannedStrength.trim().isEmpty) {
      return PrescriptionScanCheck(
        PrescriptionScanVerdict.unclear,
        sameName.first,
      );
    }
    final strength = _normaliseStrength(scannedStrength);
    final exact = sameName
        .where((m) => _normaliseStrength(m.dosage) == strength)
        .toList();
    if (exact.length == 1) {
      return PrescriptionScanCheck(
        PrescriptionScanVerdict.matchesPlan,
        exact.first,
      );
    }
    if (exact.length > 1) {
      return PrescriptionScanCheck(
        PrescriptionScanVerdict.unclear,
        exact.first,
      );
    }
    return PrescriptionScanCheck(
      PrescriptionScanVerdict.strengthMismatch,
      sameName.first,
    );
  }

  static String _normalise(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _normaliseStrength(String value) => _normalise(
    value.replaceAllMapped(
      RegExp(r'(\d)\s+(mg|mcg|g|ml|iu|units?)\b', caseSensitive: false),
      (match) => '${match.group(1)}${match.group(2)}',
    ),
  );
}
