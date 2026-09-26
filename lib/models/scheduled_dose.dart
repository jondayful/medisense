import 'medication.dart';

typedef ScheduledDose = ({Medication medication, ScheduleTime schedule});

/// Returns one entry per dose so repeated doses of the same medicine stay in
/// chronological order relative to other medicines in the same time block.
List<ScheduledDose> scheduledDosesForBlock(
  Iterable<Medication> medications,
  String block,
) {
  final doses = <ScheduledDose>[
    for (final medication in medications)
      for (final schedule in medication.schedule)
        if (schedule.label == block)
          (medication: medication, schedule: schedule),
  ];
  doses.sort((a, b) {
    final aMinutes = a.schedule.time.hour * 60 + a.schedule.time.minute;
    final bMinutes = b.schedule.time.hour * 60 + b.schedule.time.minute;
    final byTime = aMinutes.compareTo(bMinutes);
    if (byTime != 0) return byTime;
    final byName = a.medication.name.toLowerCase().compareTo(
      b.medication.name.toLowerCase(),
    );
    if (byName != 0) return byName;
    final byMedication = a.medication.id.compareTo(b.medication.id);
    if (byMedication != 0) return byMedication;
    return a.schedule.id.compareTo(b.schedule.id);
  });
  return doses;
}
