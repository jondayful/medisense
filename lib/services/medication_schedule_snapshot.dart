/// Maps the patient's active SQLite rows to the cloud schedule format.
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
  final List<Map<String, dynamic>> restores;

  const MedicationSyncPlan({required this.uploads, required this.restores});
}

MedicationSyncPlan planMedicationSync(
  List<Map<String, dynamic>> local,
  List<Map<String, dynamic>> cloud, {
  Set<String> pendingIds = const {},
}) {
  // A device can have only some of the patient's medicines. Missing local
  // rows must be restored, never interpreted as deletions. Explicit deletion
  // outbox entries are the only way to remove a cloud medicine.
  final cloudById = <String, Map<String, dynamic>>{
    for (final medication in cloud)
      if (medication['id'] is String) medication['id'] as String: medication,
  };
  final localIds = <String>{};
  final uploads = <Map<String, dynamic>>[];
  for (final medication in local) {
    final id = medication['id'] as String;
    localIds.add(id);
    if (!pendingIds.contains(id) &&
        !_sameMedication(medication, cloudById[id])) {
      uploads.add(medication);
    }
  }
  final restores = cloudById.entries
      .where(
        (entry) =>
            !localIds.contains(entry.key) && !pendingIds.contains(entry.key),
      )
      .map((entry) => entry.value)
      .toList(growable: false);
  return MedicationSyncPlan(uploads: uploads, restores: restores);
}

bool _sameMedication(Map<String, dynamic> local, Map<String, dynamic>? cloud) {
  if (cloud == null) return false;
  for (final entry in local.entries) {
    if (entry.key == 'schedules' || entry.key == 'is_active') continue;
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
