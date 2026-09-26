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
  final expirationDate = medication.expirationDate;
  final expiryStatus = expirationDate == null
      ? 'expiration date not recorded'
      : medication.isExpired
      ? 'expired on ${_formatDate(expirationDate)}, do not take'
      : medication.isExpiringSoon
      ? 'expires in ${medication.daysUntilExpiry} days, on ${_formatDate(expirationDate)}'
      : 'expires on ${_formatDate(expirationDate)}';
  return '${medication.name}, $doseWord, $doses, $expiryStatus.';
}

String _formatDate(DateTime date) => '${date.month}/${date.day}/${date.year}';
