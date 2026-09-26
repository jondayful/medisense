/// A read-only view of the patient's cloud schedule and recorded dose events.
/// Scheduled times and actual mark-as-taken timestamps are deliberately separate.
class CareDose {
  final String medicationId;
  final String scheduleId;
  final String medicationName;
  final String dosage;
  final String label;
  final int hour;
  final int minute;
  final String status;
  final DateTime? takenAt;

  const CareDose({
    required this.medicationId,
    required this.scheduleId,
    required this.medicationName,
    required this.dosage,
    required this.label,
    required this.hour,
    required this.minute,
    required this.status,
    required this.takenAt,
  });
}

class CareOverview {
  final List<CareDose> doses;
  final List<int> lastSevenDaysTaken;
  final DateTime refreshedAt;

  const CareOverview({
    required this.doses,
    required this.lastSevenDaysTaken,
    required this.refreshedAt,
  });

  int get takenToday => doses.where((dose) => dose.status == 'taken').length;
  int get dueToday => doses.length;

  static CareOverview fromCloud(
    List<Map<String, dynamic>> medications,
    List<Map<String, dynamic>> logs, {
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    final today = DateTime(current.year, current.month, current.day);
    final todayStart = today.millisecondsSinceEpoch;
    final tomorrowStart = today
        .add(const Duration(days: 1))
        .millisecondsSinceEpoch;
    final latestToday = <String, Map<String, dynamic>>{};
    final history = List<int>.filled(7, 0);
    for (final log in logs) {
      final stamp = log['timestamp'];
      final scheduleId = log['scheduleId']?.toString();
      final medicationId = log['medicationId']?.toString();
      if (stamp is! num || scheduleId == null || medicationId == null) continue;
      final millis = stamp.toInt();
      if (millis >= todayStart && millis < tomorrowStart) {
        final key = '$medicationId|$scheduleId';
        final previous = latestToday[key];
        if (previous == null ||
            (previous['timestamp'] as num).toInt() < millis) {
          latestToday[key] = log;
        }
      }
      if (log['status'] == 'taken') {
        final day = DateTime.fromMillisecondsSinceEpoch(millis);
        final calendarToday = DateTime.utc(today.year, today.month, today.day);
        final calendarDay = DateTime.utc(day.year, day.month, day.day);
        final index = 6 - calendarToday.difference(calendarDay).inDays;
        if (index >= 0 && index < 7) history[index]++;
      }
    }
    final doses = <CareDose>[];
    for (final medication in medications) {
      if (medication['is_active'] == 0 || medication['is_active'] == false) {
        continue;
      }
      final medId = medication['id']?.toString();
      if (medId == null) continue;
      final schedules = medication['schedules'];
      if (schedules is! List) continue;
      for (final value in schedules) {
        if (value is! Map) continue;
        final hour = value['hour'];
        final minute = value['minute'];
        final scheduleId = value['id']?.toString();
        if (hour is! num ||
            minute is! num ||
            scheduleId == null ||
            hour < 0 ||
            hour > 23 ||
            minute < 0 ||
            minute > 59) {
          continue;
        }
        final log = latestToday['$medId|$scheduleId'];
        final taken = log?['status'] == 'taken';
        doses.add(
          CareDose(
            medicationId: medId,
            scheduleId: scheduleId,
            medicationName: medication['name']?.toString() ?? 'Medication',
            dosage: medication['dosage']?.toString() ?? '',
            label: value['label']?.toString() ?? 'Scheduled',
            hour: hour.toInt(),
            minute: minute.toInt(),
            status: log?['status']?.toString() ?? 'pending',
            takenAt: taken
                ? DateTime.fromMillisecondsSinceEpoch(
                    (log!['timestamp'] as num).toInt(),
                  )
                : null,
          ),
        );
      }
    }
    doses.sort(
      (a, b) => (a.hour * 60 + a.minute).compareTo(b.hour * 60 + b.minute),
    );
    return CareOverview(
      doses: doses,
      lastSevenDaysTaken: history,
      refreshedAt: current,
    );
  }
}
