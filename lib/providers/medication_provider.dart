import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/medication.dart';
import '../data/database_helper.dart';
import '../services/supabase_sync_service.dart';
import 'notification_provider.dart';
import 'app_state_provider.dart';

enum DoseStatusChangeResult {
  updated,
  alreadySet,
  recentlyTaken,
  expired,
  readOnly,
  unavailable,
}

class MedicationProvider extends ChangeNotifier {
  MedicationProvider() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      (results) {
        if (results.any((result) => result != ConnectivityResult.none)) {
          unawaited(_drainSyncOutbox());
        }
      },
      onError: (Object error, StackTrace stack) =>
          debugPrint('Sync connectivity listener failed: $error'),
    );
  }

  List<Medication> _medications = [];
  final DatabaseHelper _db = DatabaseHelper();
  final SupabaseSyncService _sync = SupabaseSyncService();
  bool _isLoading = true;
  String _userId = 'guest';
  String? _viewingPatientId;
  bool _viewingPatient = false;
  NotificationProvider? _notificationProvider;
  DateTime? _lastFetchTime;
  AppStateProvider? _appStateProvider;
  bool _syncingAlarmSchedules = false;
  bool? _lastObservedAlarmEnabled;
  Future<void> _doseStatusQueue = Future<void>.value();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Future<void>? _activeOutboxDrain;
  bool _disposed = false;
  static const Duration _cacheTTL = Duration(seconds: 30);

  void updateNotificationProvider(NotificationProvider? provider) {
    final changed = !identical(_notificationProvider, provider);
    _notificationProvider = provider;
    if (changed && _medications.isNotEmpty) {
      unawaited(syncMedicationAlarms());
    }
  }

  void updateAppStateProvider(AppStateProvider? provider) {
    _appStateProvider = provider;
    final enabled = _notificationsEnabled;
    if (_lastObservedAlarmEnabled != enabled) {
      _lastObservedAlarmEnabled = enabled;
      if (_medications.isNotEmpty) unawaited(syncMedicationAlarms());
    }
  }

  String? get viewingPatientId => _viewingPatientId;
  bool get isViewingPatient => _viewingPatient;

  void updateUserId(String userId, {String? viewPatientId}) {
    final oldEffectiveId = _effectiveUserId;
    final oldWasViewing = _viewingPatient;
    _userId = userId;
    _viewingPatientId = viewPatientId;
    _viewingPatient = viewPatientId != null;

    if (_effectiveUserId == oldEffectiveId &&
        _lastFetchTime != null &&
        _viewingPatient == oldWasViewing) {
      return;
    }
    _medications.clear();
    _lastFetchTime = null;
    scheduleMicrotask(() {
      loadMedications();
    });
    if (!_viewingPatient) unawaited(_drainSyncOutbox());
  }

  void viewPatient(String patientId) {
    updateUserId(_userId, viewPatientId: patientId);
  }

  void viewOwnMedications() {
    updateUserId(_userId, viewPatientId: null);
  }

  String get _effectiveUserId => _viewingPatientId ?? _userId;

  List<Medication> get medications => List.unmodifiable(_medications);
  bool get isLoading => _isLoading;

  Future<void> loadMedications({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _lastFetchTime != null &&
        DateTime.now().difference(_lastFetchTime!) < _cacheTTL) {
      _isLoading = false;
      notifyListeners();
      return;
    }

    _isLoading = true;
    notifyListeners();

    final joinedData = await _db.getAllMedicationsWithSchedules(
      _effectiveUserId,
    );
    final allLogs = await _db.getTodayLogsForUser(_effectiveUserId);

    final Map<String, List<Map<String, dynamic>>> medGroups = {};
    for (var row in joinedData) {
      final medId = row['med_id'] as String;
      medGroups.putIfAbsent(medId, () => []).add(row);
    }

    final Map<String, Map<String, String>> logMap = {};
    for (var log in allLogs) {
      logMap[log['schedule_id'] as String] = log.cast<String, String>();
    }

    List<Medication> loadedMeds = [];
    for (var medId in medGroups.keys) {
      final rows = medGroups[medId]!;
      final first = rows.first;

      List<ScheduleTime> scheduleItems = [];
      for (var row in rows) {
        final schedId = row['sched_id'];
        if (schedId == null) continue;
        final logEntry = logMap[schedId as String];
        scheduleItems.add(
          ScheduleTime(
            id: schedId,
            label: row['sched_label'],
            time: TimeOfDay(
              hour: row['sched_hour'],
              minute: row['sched_minute'],
            ),
            taken: logEntry != null && logEntry['status'] == 'taken',
          ),
        );
      }

      final colorHex = first['med_color_hex'] as String?;
      final expDate = first['med_expiration_date'] as String?;

      loadedMeds.add(
        Medication(
          id: medId,
          name: first['med_name'] ?? '',
          dosage: first['med_dosage'] ?? '',
          form: first['med_form'] ?? 'Tablet',
          color: _parseColor(colorHex),
          schedule: scheduleItems,
          frequency:
              (first['med_frequency'] as String?) ??
              Medication.frequencyForSchedule(scheduleItems),
          expirationDate: _parseDateOrNull(expDate),
          quantityDispensed: first['med_quantity_dispensed'] as int?,
          unitsPerDose: (first['med_units_per_dose'] as num?)?.toDouble(),
          prescriptionStartDate: _parseDateOrNull(
            first['med_prescription_start_date'] as String?,
          ),
          prescriptionReviewed:
              (first['med_prescription_reviewed'] as int? ?? 0) == 1,
        ),
      );
    }

    _medications = loadedMeds;
    _isLoading = false;
    _lastFetchTime = DateTime.now();
    notifyListeners();
    unawaited(syncMedicationAlarms());
  }

  /// Rebuilds device alarms from the local database. Android's AlarmManager
  /// entries survive process death; this also repairs them after an app
  /// update, permission change, or device restore.
  Future<void> syncMedicationAlarms() async {
    final notifications = _notificationProvider;
    if (notifications == null || _syncingAlarmSchedules || _viewingPatient) {
      return;
    }
    _syncingAlarmSchedules = true;
    try {
      if (!_notificationsEnabled) {
        await notifications.cancelAllMedicationAlarms();
        return;
      }
      final alarms = <Map<String, dynamic>>[
        for (final medication in _medications)
          if (!medication.isExpired && medication.frequency != 'As needed')
            for (final schedule in medication.schedule)
              {
                'id': notifications.safeNotificationId(schedule.id),
                'title': '${medication.name} due now',
                'body':
                    'Hello, ${_appStateProvider?.savedUserName ?? _appStateProvider?.onboardingName ?? 'kaibigan'} oras na para uminom ng ${medication.name}',
                'time': schedule.time,
                'medicationId': medication.id,
                'scheduleId': schedule.id,
              },
      ];
      await notifications.synchronizeMedicationAlarms(alarms);
    } catch (error) {
      debugPrint('Could not synchronize medication alarms: $error');
    } finally {
      _syncingAlarmSchedules = false;
    }
  }

  Color _parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return const Color(0xFF00897B);
    try {
      return Color(int.parse(hex, radix: 16));
    } catch (_) {
      return const Color(0xFF00897B);
    }
  }

  DateTime? _parseDateOrNull(String? date) {
    if (date == null || date.isEmpty) return null;
    return DateTime.tryParse(date);
  }

  String? _cloudExpirationDate(Map<String, dynamic> medication) {
    final expirationDate = _parseDateOrNull(
      medication['expiration_date'] as String?,
    );
    final prescriptionStartDate = _parseDateOrNull(
      medication['prescription_start_date'] as String?,
    );
    if (Medication.isLegacyDefaultExpiration(
      expirationDate: expirationDate,
      prescriptionStartDate: prescriptionStartDate,
    )) {
      return null;
    }
    return medication['expiration_date'] as String?;
  }

  void invalidateCache() {
    _lastFetchTime = null;
  }

  Future<DoseStatusChangeResult> toggleDoseStatus(
    String medId,
    String scheduleId,
    bool taken, {
    DateTime? recordedAt,
  }) {
    final operation = _doseStatusQueue.then(
      (_) => _applyDoseStatus(medId, scheduleId, taken, recordedAt: recordedAt),
    );
    _doseStatusQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<DoseStatusChangeResult> _applyDoseStatus(
    String medId,
    String scheduleId,
    bool taken, {
    DateTime? recordedAt,
  }) async {
    if (_viewingPatient) return DoseStatusChangeResult.readOnly;
    var medication = getById(medId);
    if (medication == null) {
      await loadMedications(forceRefresh: true);
      medication = getById(medId);
    }
    if (medication == null) return DoseStatusChangeResult.unavailable;
    final scheduleIndex = medication.schedule.indexWhere(
      (schedule) => schedule.id == scheduleId,
    );
    if (scheduleIndex < 0) return DoseStatusChangeResult.unavailable;
    final schedule = medication.schedule[scheduleIndex];
    if (schedule.taken == taken) return DoseStatusChangeResult.alreadySet;
    if (taken) {
      if (medication.isExpired) return DoseStatusChangeResult.expired;
      if (await wasRecentlyTaken(medId, scheduleId)) {
        return DoseStatusChangeResult.recentlyTaken;
      }
    }

    final status = taken ? 'taken' : 'pending';
    final eventTime = recordedAt ?? DateTime.now();
    final userUuid = SupabaseSyncService.nullableUuid(_userId);
    final startOfDay = DateTime(
      eventTime.year,
      eventTime.month,
      eventTime.day,
    ).millisecondsSinceEpoch;
    final logId = '${medId}_${scheduleId}_$startOfDay';
    final payload = {
      'medicationId': medId,
      'scheduleId': scheduleId,
      'status': status,
      'timestamp': eventTime.millisecondsSinceEpoch,
      'patientId': _userId,
    };
    if (userUuid == null) {
      await _db.updateAdherenceLog(
        medId,
        scheduleId,
        status,
        recordedAt: eventTime,
      );
    } else {
      await _db.updateAdherenceLogAndQueue(
        medId: medId,
        scheduleId: scheduleId,
        status: status,
        recordedAt: eventTime,
        outboxId: 'adherence:$userUuid:$logId',
        userId: userUuid,
        payload: payload,
      );
    }

    schedule.taken = taken;
    notifyListeners();
    if (userUuid != null) unawaited(_drainSyncOutbox());
    return DoseStatusChangeResult.updated;
  }

  void toggleTaken(String medicationId, int scheduleIndex) {
    final medIndex = _medications.indexWhere((m) => m.id == medicationId);
    if (medIndex == -1) return;
    final med = _medications[medIndex];
    if (scheduleIndex >= med.schedule.length) return;
    final schedule = med.schedule[scheduleIndex];
    toggleDoseStatus(medicationId, schedule.id, !schedule.taken);
  }

  Medication? getById(String id) {
    try {
      return _medications.firstWhere((m) => m.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Untaken doses whose scheduled time is now or earlier, sorted by time.
  /// Backs the dashboard's "doses due now" hero and the elder check-in queue.
  List<({Medication med, ScheduleTime s})> get dosesDueNow =>
      dosesDueNowFor(_medications, TimeOfDay.now());

  static List<({Medication med, ScheduleTime s})> dosesDueNowFor(
    List<Medication> medications,
    TimeOfDay now,
  ) {
    final nowMinutes = _timeOfDayToMinutes(now);
    final due = <({Medication med, ScheduleTime s})>[];
    for (final m in medications) {
      for (final s in m.schedule) {
        if (!s.taken && _timeOfDayToMinutes(s.time) <= nowMinutes) {
          due.add((med: m, s: s));
        }
      }
    }
    due.sort((a, b) {
      final ca = _timeOfDayToMinutes(a.s.time);
      final cb = _timeOfDayToMinutes(b.s.time);
      return ca.compareTo(cb);
    });
    return due;
  }

  static int _timeOfDayToMinutes(TimeOfDay t) => t.hour * 60 + t.minute;

  /// Defers the dose that is due now. The schedule is untouched; the reminder
  /// simply fires again shortly.
  Future<void> snoozeDose({
    required String medId,
    required String scheduleId,
  }) async {
    await _notificationProvider?.snoozeMedicationAlarm(
      medicationId: medId,
      scheduleId: scheduleId,
    );
  }

  Future<DateTime?> lastTakenAt(String medId, String scheduleId) =>
      _db.lastTakenAt(medId, scheduleId);

  /// True when this dose was marked taken within [window] — the duplicate-dose
  /// guard before re-marking.
  Future<bool> wasRecentlyTaken(
    String medId,
    String scheduleId, {
    Duration window = const Duration(minutes: 20),
  }) async {
    final last = await _db.lastTakenAt(medId, scheduleId);
    if (last == null) return false;
    return DateTime.now().difference(last) <= window;
  }

  Future<void> markBatchTaken(
    List<({String medId, String scheduleId})> items,
  ) async {
    for (final item in items) {
      await toggleDoseStatus(item.medId, item.scheduleId, true);
    }
  }

  /// The earliest untaken dose across all medications, used by the voice
  /// "where am I" context and dashboards.
  ({Medication med, ScheduleTime s})? get nextPendingDose {
    final pending = <({Medication med, ScheduleTime s})>[];
    for (final m in _medications) {
      for (final s in m.schedule) {
        if (!s.taken) pending.add((med: m, s: s));
      }
    }
    if (pending.isEmpty) return null;
    pending.sort((a, b) {
      final ca = a.s.time.hour * 60 + a.s.time.minute;
      final cb = b.s.time.hour * 60 + b.s.time.minute;
      return ca.compareTo(cb);
    });
    return pending.first;
  }

  bool get _notificationsEnabled =>
      _appStateProvider?.notificationsEnabled ?? true;

  Future<void> _cancelExistingNotifications(String medId) async {
    if (_notificationProvider == null) return;
    final existingSchedules = await _db.getSchedulesForMedication(medId);
    for (var s in existingSchedules) {
      final safeId = _notificationProvider!.safeNotificationId(
        s['id'] as String,
      );
      await _notificationProvider!.cancelNotification(safeId);
    }
  }

  Future<void> addMedication(Medication medication) async {
    if (_viewingPatient) return;
    final Map<String, dynamic> medMap = {
      'id': medication.id,
      'name': medication.name,
      'dosage': medication.dosage,
      'form': medication.form,
      'color_hex': medication.color.toARGB32().toRadixString(16),
      'expiration_date': medication.expirationDate?.toIso8601String(),
      'frequency': medication.frequency,
      'quantity_dispensed': medication.quantityDispensed,
      'units_per_dose': medication.unitsPerDose,
      'prescription_start_date': medication.prescriptionStartDate
          ?.toIso8601String(),
      'prescription_reviewed': medication.prescriptionReviewed ? 1 : 0,
      'user_id': _userId,
    };
    await _db.saveMedicationAndSchedules(
      medMap,
      medication.schedule
          .map(
            (s) => {
              'id': s.id,
              'medication_id': medication.id,
              'label': s.label,
              'hour': s.time.hour,
              'minute': s.time.minute,
            },
          )
          .toList(),
      replaceSchedules: false,
    );
    for (var s in medication.schedule) {
      if (_notificationProvider != null && _notificationsEnabled) {
        final safeId = _notificationProvider!.safeNotificationId(s.id);
        await _notificationProvider!.scheduleMedicationNotification(
          id: safeId,
          title: '${medication.name} due now',
          body: '${medication.dosage}, ${medication.form}',
          time: s.time,
          medicationId: medication.id,
          scheduleId: s.id,
        );
      }
    }
    invalidateCache();
    await loadMedications(forceRefresh: true);
    await _queueMedicationSync(medication.id, medMap);
  }

  Future<void> editMedication(Medication medication) async {
    if (_viewingPatient) return;
    await _cancelExistingNotifications(medication.id);

    final Map<String, dynamic> medMap = {
      'id': medication.id,
      'name': medication.name,
      'dosage': medication.dosage,
      'form': medication.form,
      'color_hex': medication.color.toARGB32().toRadixString(16),
      'expiration_date': medication.expirationDate?.toIso8601String(),
      'frequency': medication.frequency,
      'quantity_dispensed': medication.quantityDispensed,
      'units_per_dose': medication.unitsPerDose,
      'prescription_start_date': medication.prescriptionStartDate
          ?.toIso8601String(),
      'prescription_reviewed': medication.prescriptionReviewed ? 1 : 0,
      'user_id': _userId,
    };
    await _db.saveMedicationAndSchedules(
      medMap,
      medication.schedule
          .map(
            (s) => {
              'id': s.id,
              'medication_id': medication.id,
              'label': s.label,
              'hour': s.time.hour,
              'minute': s.time.minute,
            },
          )
          .toList(),
      replaceSchedules: true,
    );
    for (var s in medication.schedule) {
      if (_notificationProvider != null && _notificationsEnabled) {
        final safeId = _notificationProvider!.safeNotificationId(s.id);
        await _notificationProvider!.scheduleMedicationNotification(
          id: safeId,
          title: '${medication.name} due now',
          body: '${medication.dosage}, ${medication.form}',
          time: s.time,
          medicationId: medication.id,
          scheduleId: s.id,
        );
      }
    }
    invalidateCache();
    await loadMedications(forceRefresh: true);
    await _queueMedicationSync(medication.id, medMap);
  }

  /// Moves one recurring dose while preserving its schedule ID and adherence
  /// history. Replacing the schedule row would cascade-delete the dose logs.
  Future<bool> moveScheduleTime(
    String medicationId,
    String scheduleId,
    TimeOfDay time,
  ) async {
    if (_viewingPatient) return false;
    final medicationIndex = _medications.indexWhere(
      (medication) => medication.id == medicationId,
    );
    if (medicationIndex < 0) return false;
    final medication = _medications[medicationIndex];
    final scheduleIndex = medication.schedule.indexWhere(
      (schedule) => schedule.id == scheduleId,
    );
    if (scheduleIndex < 0) return false;

    final oldSchedule = medication.schedule[scheduleIndex];
    final updatedSchedule = ScheduleTime(
      id: oldSchedule.id,
      label: ScheduleTime.labelFor(time.hour),
      time: time,
      taken: oldSchedule.taken,
    );
    await _db.updateScheduleTime(
      scheduleId,
      label: updatedSchedule.label,
      hour: time.hour,
      minute: time.minute,
    );
    medication.schedule[scheduleIndex] = updatedSchedule;
    _lastFetchTime = DateTime.now();
    notifyListeners();
    await syncMedicationAlarms();
    await _queueMedicationSync(medication.id, {
      'id': medication.id,
      'name': medication.name,
      'dosage': medication.dosage,
      'form': medication.form,
      'color_hex': medication.color.toARGB32().toRadixString(16),
      'expiration_date': medication.expirationDate?.toIso8601String(),
      'frequency': medication.frequency,
      'quantity_dispensed': medication.quantityDispensed,
      'units_per_dose': medication.unitsPerDose,
      'prescription_start_date': medication.prescriptionStartDate
          ?.toIso8601String(),
      'prescription_reviewed': medication.prescriptionReviewed ? 1 : 0,
      'user_id': _userId,
    });
    return true;
  }

  Future<void> removeMedication(String id) async {
    if (_viewingPatient) return;
    await _cancelExistingNotifications(id);
    await _db.deleteMedication(id, _userId);
    invalidateCache();
    await loadMedications(forceRefresh: true);
    final userUuid = SupabaseSyncService.nullableUuid(_userId);
    if (userUuid != null) {
      await _db.enqueueSyncOperation(
        id: 'medication:$userUuid:$id',
        operation: 'deleteMedication',
        userId: userUuid,
        payload: {'medicationId': id},
      );
      unawaited(_drainSyncOutbox());
    }
  }

  List<Medication> get morningMeds => _medications
      .where((m) => m.schedule.any((s) => s.label == 'Morning'))
      .toList();

  List<Medication> get afternoonMeds => _medications
      .where((m) => m.schedule.any((s) => s.label == 'Afternoon'))
      .toList();

  List<Medication> get eveningMeds => _medications
      .where((m) => m.schedule.any((s) => s.label == 'Evening'))
      .toList();

  List<Medication> get nightMeds => _medications
      .where((m) => m.schedule.any((s) => s.label == 'Night'))
      .toList();

  double get overallAdherence {
    if (_medications.isEmpty) return 0;
    int total = 0;
    int taken = 0;
    for (var m in _medications) {
      total += m.dailyDoses;
      taken += m.takenDoses;
    }
    return total == 0 ? 0 : taken / total;
  }

  int get totalMissedDoses {
    int missed = 0;
    final now = TimeOfDay.now();
    for (var m in _medications) {
      for (var s in m.schedule) {
        if (!s.taken &&
            (s.time.hour < now.hour ||
                (s.time.hour == now.hour && s.time.minute < now.minute))) {
          missed++;
        }
      }
    }
    return missed;
  }

  int get totalDoses =>
      _medications.fold<int>(0, (sum, m) => sum + m.dailyDoses);

  int get totalTaken =>
      _medications.fold<int>(0, (sum, m) => sum + m.takenDoses);

  Future<void> _queueMedicationSync(
    String medId,
    Map<String, dynamic> medMap,
  ) async {
    final userUuid = SupabaseSyncService.nullableUuid(_userId);
    if (userUuid == null) return;
    final schedules = _medications
        .where((m) => m.id == medId)
        .expand((m) => m.schedule)
        .map(
          (s) => {
            'id': s.id,
            'label': s.label,
            'hour': s.time.hour,
            'minute': s.time.minute,
          },
        )
        .toList();
    await _db.enqueueSyncOperation(
      id: 'medication:$userUuid:$medId',
      operation: 'medication',
      userId: userUuid,
      payload: {...medMap, 'schedules': schedules},
    );
    unawaited(_drainSyncOutbox());
  }

  Future<void> _drainSyncOutbox() {
    if (_disposed || _viewingPatient) return Future<void>.value();
    final active = _activeOutboxDrain;
    if (active != null) return active;
    final drain = _runOutboxDrain();
    _activeOutboxDrain = drain;
    return drain.whenComplete(() => _activeOutboxDrain = null);
  }

  Future<void> _runOutboxDrain() async {
    if (SupabaseSyncService.nullableUuid(_userId) == null ||
        !_sync.isInitialized) {
      return;
    }
    try {
      final operations = await _db.pendingSyncOperations();
      for (final operation in operations) {
        if (_disposed || operation['user_id'] != _userId) continue;
        final id = operation['id'] as String;
        final expectedPayload = operation['payload_json'] as String;
        final payload = operation['payload'] as Map<String, dynamic>;
        bool synced;
        try {
          switch (operation['operation']) {
            case 'adherence':
              final logId = id.substring(id.lastIndexOf(':') + 1);
              synced = await _sync.uploadAdherenceLog(
                patientId: _userId,
                logId: logId,
                data: payload,
              );
            case 'medication':
              final medId = payload['id'] as String;
              synced = await _sync.uploadMedication(
                patientId: _userId,
                medicationId: medId,
                data: payload,
              );
            case 'deleteMedication':
              synced = await _sync.deleteMedication(
                patientId: _userId,
                medicationId: payload['medicationId'] as String,
              );
            default:
              await _db.completeSyncOperation(id);
              continue;
          }
          if (synced) {
            await _db.completeSyncOperation(
              id,
              expectedPayload: expectedPayload,
            );
          } else {
            await _db.retrySyncOperation(
              id,
              'Supabase sync unavailable',
              expectedPayload: expectedPayload,
            );
          }
        } catch (error) {
          await _db.retrySyncOperation(
            id,
            error,
            expectedPayload: expectedPayload,
          );
        }
      }
    } catch (error) {
      debugPrint('Could not drain sync outbox: $error');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_connectivitySubscription?.cancel());
    super.dispose();
  }

  Future<void> pullPatientDataFromCloud(String patientId) async {
    final remoteMeds = await _sync.fetchPatientMedications(patientId);
    final remoteLogs = await _sync.fetchPatientLogs(patientId);

    for (var med in remoteMeds) {
      final medId = med['id'] as String?;
      if (medId == null) continue;

      await _db.insertMedication({
        'id': medId,
        'name': med['name'] ?? '',
        'dosage': med['dosage'] ?? '',
        'form': med['form'] ?? 'Tablet',
        'color_hex': med['color_hex'] ?? 'ff00897B',
        'expiration_date': _cloudExpirationDate(med),
        'frequency': med['frequency'],
        'quantity_dispensed': med['quantity_dispensed'],
        'units_per_dose': med['units_per_dose'],
        'prescription_start_date': med['prescription_start_date'],
        'prescription_reviewed':
            med['prescription_reviewed'] == true ||
                med['prescription_reviewed'] == 1
            ? 1
            : 0,
        'user_id': patientId,
      });

      final schedules = med['schedules'] as List<dynamic>? ?? [];
      for (var sched in schedules) {
        if (sched is Map) {
          final schedId = sched['id'] as String?;
          if (schedId == null) continue;
          await _db.insertSchedule({
            'id': schedId,
            'medication_id': medId,
            'label': sched['label'] ?? 'Scheduled',
            'hour': sched['hour'] ?? 8,
            'minute': sched['minute'] ?? 0,
          });
        }
      }
    }

    for (var log in remoteLogs) {
      if (log['medicationId'] != null && log['scheduleId'] != null) {
        await _db.updateAdherenceLog(
          log['medicationId'] as String,
          log['scheduleId'] as String,
          log['status'] as String? ?? 'pending',
          recordedAt: log['timestamp'] is num
              ? DateTime.fromMillisecondsSinceEpoch(
                  (log['timestamp'] as num).toInt(),
                )
              : null,
        );
      }
    }

    invalidateCache();
    await loadMedications(forceRefresh: true);
  }
}
