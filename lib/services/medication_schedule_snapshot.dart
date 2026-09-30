/// The patient's active SQLite rows are the source for the caregiver's cloud
/// schedule. Keep this mapping in one place so reconciliation compares exactly
/// the data that it uploads.
List<Map<String, dynamic>> medicationSnapshotFromRows(
  List<Map<String, dynamic>> rows,
) {
  final byId = <String, Map<String, dynamic>>{};
  for (final row in rows) {
    final id = row['med_id'] as String?;
    if (id == null) continue;
    final medication = byId.putIfAbsent(
      id,
      () => <String, dynamic>{
        'id': id,
        'name': row['med_name'],
        'dosage': row['med_dosage'],
        'form': row['med_form'],
        'color_hex': row['med_color_hex'],
        'expiration_date': row['med_expiration_date'],
        'frequency': row['med_frequency'],
        'quantity_dispensed': row['med_quantity_dispensed'],
        'units_per_dose': row['med_units_per_dose'],
        'prescription_start_date': row['med_prescription_start_date'],
        'prescription_reviewed': row['med_prescription_reviewed'],
        'user_id': row['med_user_id'],
        'is_active': 1,
        'schedules': <Map<String, dynamic>>[],
      },
    );
    final scheduleId = row['sched_id'] as String?;
    if (scheduleId == null) continue;
    (medication['schedules'] as List<Map<String, dynamic>>).add({
      'id': scheduleId,
      'label': row['sched_label'],
      'hour': row['sched_hour'],
      'minute': row['sched_minute'],
    });
  }
  for (final medication in byId.values) {
    (medication['schedules'] as List<Map<String, dynamic>>).sort(
      (a, b) => (a['id'] as String).compareTo(b['id'] as String),
    );
  }
  return byId.values.toList(growable: false);
}

class MedicationSyncPlan {
  final List<Map<String, dynamic>> uploads;
  final List<String> deletes;

  const MedicationSyncPlan({required this.uploads, required this.deletes});
}

MedicationSyncPlan planMedicationSync(
  List<Map<String, dynamic>> local,
  List<Map<String, dynamic>> cloud,
) {
  // A fresh device can have an empty SQLite database before its cloud history
  // is restored. Explicit deletion outbox entries still remove medicines that
  // the patient actually deleted on this device.
  if (local.isEmpty) {
    return const MedicationSyncPlan(uploads: [], deletes: []);
  }
  final cloudById = <String, Map<String, dynamic>>{
    for (final medication in cloud)
      if (medication['id'] is String) medication['id'] as String: medication,
  };
  final localIds = <String>{};
  final uploads = <Map<String, dynamic>>[];
  for (final medication in local) {
    final id = medication['id'] as String;
    localIds.add(id);
    if (!_sameMedication(medication, cloudById[id])) uploads.add(medication);
  }
  final deletes = cloudById.keys
      .where((id) => !localIds.contains(id))
      .toList(growable: false);
  return MedicationSyncPlan(uploads: uploads, deletes: deletes);
}

bool _sameMedication(Map<String, dynamic> local, Map<String, dynamic>? cloud) {
  if (cloud == null) return false;
  for (final entry in local.entries) {
    if (entry.key == 'schedules') continue;
    if (cloud[entry.key] != entry.value) return false;
  }
  final localSchedules = local['schedules'] as List<Map<String, dynamic>>;
  final cloudSchedules = cloud['schedules'];
  if (cloudSchedules is! List ||
      cloudSchedules.length != localSchedules.length) {
    return false;
  }
  final cloudById = <String, Map>{};
  for (final schedule in cloudSchedules) {
    if (schedule is! Map || schedule['id'] is! String) return false;
    cloudById[schedule['id'] as String] = schedule;
  }
  if (cloudById.length != localSchedules.length) return false;
  for (final schedule in localSchedules) {
    final other = cloudById[schedule['id']];
    if (other == null ||
        other['label'] != schedule['label'] ||
        other['hour'] != schedule['hour'] ||
        other['minute'] != schedule['minute']) {
      return false;
    }
  }
  return true;
}
