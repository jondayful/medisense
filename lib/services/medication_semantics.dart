import '../models/medication.dart';

String medicationSemanticsLabel(
  Medication medication, {
  String? filterLabel,
  String? scheduleId,
}) {
  final schedule = medication.schedule
      .where(
        (s) =>
            (filterLabel == null || s.label == filterLabel) &&
            (scheduleId == null || s.id == scheduleId),
      )
      .toList();
  final doses = schedule.isEmpty
      ? 'no scheduled doses'
      : schedule
            .map(
              (s) =>
                  '${s.label} at ${s.formattedTime}, status: ${s.taken ? 'taken' : 'pending'}',
            )
            .join('; ');
  final doseWord = medication.dosage.isEmpty
      ? medication.form
      : '${medication.dosage} ${medication.form}';
  final expiration =
      '${medication.expirationDate.month}/${medication.expirationDate.day}/${medication.expirationDate.year}';
  final expiryStatus = medication.isExpired
      ? 'expired on $expiration, do not take'
      : medication.isExpiringSoon
      ? 'expires in ${medication.daysUntilExpiry} days, on $expiration'
      : 'expires on $expiration';
  return '${medication.name}, $doseWord, $doses, $expiryStatus.';
}
