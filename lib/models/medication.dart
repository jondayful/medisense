import 'package:flutter/material.dart';
import 'dosage.dart';

const List<String> kFrequencyOptions = [
  'Once a day',
  'Twice a day',
  'Three times a day',
  'Every 4 hours',
  'Every 6 hours',
  'Every 8 hours',
  'Every 12 hours',
  'As needed',
];

/// Choices available in the guided scan flow. Keep this aligned with the
/// schedule model so spoken frequencies and visible options can both be used.
const List<String> kGuidedFrequencies = kFrequencyOptions;

class ScheduleTime {
  static const List<String> blocks = [
    'Morning',
    'Afternoon',
    'Evening',
    'Night',
  ];

  static String labelFor(int hour) {
    if (hour >= 5 && hour < 12) return 'Morning';
    if (hour >= 12 && hour < 17) return 'Afternoon';
    if (hour >= 17 && hour < 21) return 'Evening';
    return 'Night';
  }

  static String formatTime(TimeOfDay time) {
    final hour = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
    final minute = time.minute.toString().padLeft(2, '0');
    final period = time.period == DayPeriod.am ? 'AM' : 'PM';
    return '$hour:$minute $period';
  }

  static List<ScheduleTime> buildSchedule({
    required String medId,
    required TimeOfDay start,
    required String frequency,
    Map<String, bool> preservedTaken = const {},
  }) {
    if (frequency == 'As needed') return const [];
    var intervalHours = 0;
    var count = 1;
    switch (frequency) {
      case 'Twice a day':
      case 'Every 12 hours':
        count = 2;
        intervalHours = 12;
        break;
      case 'Three times a day':
      case 'Every 8 hours':
        count = 3;
        intervalHours = 8;
        break;
      case 'Every 6 hours':
        count = 4;
        intervalHours = 6;
        break;
      case 'Every 4 hours':
        count = 6;
        intervalHours = 4;
        break;
      case 'Once a day':
      default:
        count = 1;
        break;
    }

    final schedules = <ScheduleTime>[];
    for (var i = 0; i < count; i++) {
      final h = (start.hour + (i * intervalHours)) % 24;
      final schedId = '${medId}_${h}_${start.minute}';
      schedules.add(
        ScheduleTime(
          id: schedId,
          time: TimeOfDay(hour: h, minute: start.minute),
          label: labelFor(h),
          taken: preservedTaken[schedId] ?? false,
        ),
      );
    }
    return schedules;
  }

  final String id; // Added ID for database mapping
  final TimeOfDay time;
  final String label;
  bool taken;

  ScheduleTime({
    required this.id,
    required this.time,
    required this.label,
    this.taken = false,
  });

  String get formattedTime => formatTime(time);

  Map<String, dynamic> toJson() => {
    'hour': time.hour,
    'minute': time.minute,
    'label': label,
    'taken': taken,
  };
}

class Medication {
  static const expiryWarningDays = 30;
  static const _legacyDefaultExpiryWindow = Duration(seconds: 5);

  /// Matches the old form's fabricated `now + 365 days` value. Keeping this
  /// narrow lets upgrades remove those defaults without clearing a date read
  /// from a label (which is stored at midnight or at the end of its month).
  static bool isLegacyDefaultExpiration({
    required DateTime? expirationDate,
    required DateTime? prescriptionStartDate,
  }) {
    if (expirationDate == null || prescriptionStartDate == null) return false;
    final difference = expirationDate.difference(prescriptionStartDate);
    final defaultDifference = const Duration(days: 365);
    return (difference - defaultDifference).abs() < _legacyDefaultExpiryWindow;
  }

  /// Structured read of [dosage]: unit-preserving, never clamped. Null when
  /// the stored string carries no dose at all.
  Dosage? get parsedDosage => Dosage.parse(dosage);

  /// Legacy read path: the stored schedule cannot tell the ambiguous pairs
  /// apart ('Twice a day' vs 'Every 12 hours', 'Three times a day' vs
  /// 'Every 8 hours', 'Once a day' vs 'As needed'), so a missing frequency is
  /// resolved to the count-based representative, matching the old modal.
  static String frequencyForSchedule(List<ScheduleTime> schedule) {
    switch (schedule.length) {
      case 2:
        return 'Twice a day';
      case 3:
        return 'Three times a day';
      case 4:
        return 'Every 6 hours';
      case 6:
        return 'Every 4 hours';
      case 1:
      default:
        return 'Once a day';
    }
  }

  final String id;
  final String name;
  final String dosage;
  final String form;
  final DateTime? expirationDate;
  final List<ScheduleTime> schedule;
  final String frequency;
  final String notes;
  final Color color;
  final int? quantityDispensed;
  final double? unitsPerDose;
  final DateTime? prescriptionStartDate;
  final bool prescriptionReviewed;

  Medication({
    required this.id,
    required this.name,
    required this.dosage,
    required this.form,
    required this.expirationDate,
    required this.schedule,
    required this.frequency,
    this.notes = '',
    this.color = const Color(0xFF00897B),
    this.quantityDispensed,
    this.unitsPerDose,
    this.prescriptionStartDate,
    this.prescriptionReviewed = false,
  });

  DateTime? get expirationDay {
    final date = expirationDate;
    if (date == null) return null;
    return DateTime(date.year, date.month, date.day);
  }

  int? get daysUntilExpiry {
    final expiryDay = expirationDay;
    if (expiryDay == null) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return expiryDay.difference(today).inDays;
  }

  bool get isExpired => (daysUntilExpiry ?? 0) < 0;

  bool get isExpiringSoon {
    final days = daysUntilExpiry;
    return days != null && !isExpired && days <= expiryWarningDays;
  }

  int get dailyDoses => schedule.length;

  int get takenDoses => schedule.where((s) => s.taken).length;

  double get adherenceToday => schedule.isEmpty ? 0 : takenDoses / dailyDoses;

  /// Intentionally unavailable for PRN and incomplete prescriptions.
  int? get estimatedDaysSupply {
    if (frequency == 'As needed' ||
        quantityDispensed == null ||
        unitsPerDose == null ||
        unitsPerDose! <= 0 ||
        dailyDoses <= 0) {
      return null;
    }
    return (quantityDispensed! / (unitsPerDose! * dailyDoses)).floor();
  }

  DateTime? get estimatedRunOutDate {
    final days = estimatedDaysSupply;
    if (days == null || prescriptionStartDate == null) return null;
    return prescriptionStartDate!.add(Duration(days: days));
  }
}
