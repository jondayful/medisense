import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;
import '../data/database_helper.dart';
import '../services/medication_alarm_message.dart';
import 'medication_provider.dart';
import 'tts_provider.dart';

const String _kPendingActionKey = 'pendingNotificationAction';
const MethodChannel _nativeAlarmChannel = MethodChannel('medisense/alarm');

/// Background notification-action handler. Runs in a separate isolate, so it
/// cannot reach the app's providers — it persists the action and the app
/// resolves it on next foreground.
@pragma('vm:entry-point')
Future<void> notificationBackgroundHandler(
  NotificationResponse response,
) async {
  DartPluginRegistrant.ensureInitialized();
  // Action callbacks may run while the Flutter UI is not alive. Cancel the
  // ongoing notification in this isolate so Mark Taken is immediate.
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    ),
  );
  if (response.id != null) {
    await plugin.cancel(response.id!);
  }
  if (response.actionId == 'mark_taken' && response.payload != null) {
    final medicationId = RegExp(
      r'med:([^|]+)',
    ).firstMatch(response.payload!)?.group(1);
    final scheduleId = RegExp(
      r'sched:([^|]+)',
    ).firstMatch(response.payload!)?.group(1);
    if (medicationId != null && scheduleId != null) {
      // Keep the local SQLite source of truth current even when the user
      // acts from the lock-screen notification while the app is terminated.
      await DatabaseHelper().updateAdherenceLog(
        medicationId,
        scheduleId,
        'taken',
      );
    }
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    _kPendingActionKey,
    jsonEncode({'actionId': response.actionId, 'payload': response.payload}),
  );
}

class NotificationProvider extends ChangeNotifier {
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  GoRouter? _router;
  MedicationProvider? _medicationProvider;
  TtsProvider? _ttsProvider;
  late final Future<void> _initialization;

  NotificationProvider() {
    _initialization = _initNotifications();
  }

  void setRouter(GoRouter router) {
    _router = router;
  }

  void setMedicationProvider(MedicationProvider? provider) {
    _medicationProvider = provider;
  }

  void setTtsProvider(TtsProvider? tts) {
    _ttsProvider = tts;
  }

  Future<void> _initNotifications() async {
    _nativeAlarmChannel.setMethodCallHandler((call) async {
      if (call.method != 'alarmAction' || call.arguments is! Map) return null;
      final action = call.arguments as Map;
      final medicationId = action['medicationId'] as String?;
      final scheduleId = action['scheduleId'] as String?;
      if (medicationId == null || scheduleId == null) return null;
      if (action['type'] == 'open') {
        _router?.go(
          '/alarm',
          extra: {'medicationId': medicationId, 'scheduleId': scheduleId},
        );
        return null;
      }
      await _persistMarkTakenAction(medicationId, scheduleId);
      if (_medicationProvider != null) await resolvePendingAction();
      return null;
    });

    tz_data.initializeTimeZones();
    try {
      final deviceZone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(deviceZone.identifier));
    } catch (e) {
      // Keep startup working on platforms where the native timezone plugin is
      // unavailable. Android/iOS builds should normally take the path above.
      debugPrint('Could not determine device timezone: $e');
    }

    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings initializationSettingsIOS =
        DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
          // Apple only grants this after the Critical Alerts entitlement is
          // approved. The request is harmless without the entitlement and falls
          // back to normal/time-sensitive notification delivery.
          requestCriticalPermission: true,
        );

    const InitializationSettings initializationSettings =
        InitializationSettings(
          android: initializationSettingsAndroid,
          iOS: initializationSettingsIOS,
        );

    await _notificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
      onDidReceiveBackgroundNotificationResponse: notificationBackgroundHandler,
    );
    final launchDetails = await _notificationsPlugin
        .getNotificationAppLaunchDetails();
    final launchResponse = launchDetails?.notificationResponse;
    if (launchDetails?.didNotificationLaunchApp == true &&
        launchResponse?.payload != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kPendingActionKey,
        jsonEncode({
          'actionId': launchResponse?.actionId,
          'payload': launchResponse?.payload,
        }),
      );
    }
    if (Platform.isAndroid) {
      final alarmAction = await _nativeAlarmChannel
          .invokeMapMethod<String, dynamic>('takeLaunchAlarmAction');
      final medicationId = alarmAction?['medicationId'] as String?;
      final scheduleId = alarmAction?['scheduleId'] as String?;
      if (medicationId != null && scheduleId != null) {
        if (alarmAction?['type'] == 'open') {
          // The router is attached after initialization; resolve on startup.
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(
            _kPendingActionKey,
            jsonEncode({
              'actionId': 'open_alarm',
              'payload': 'med:$medicationId|sched:$scheduleId',
            }),
          );
        } else {
          await _persistMarkTakenAction(medicationId, scheduleId);
        }
      }
      // Remove alarms created by the older notification-only implementation.
      // New Android reminders are scheduled through AlarmManager below.
      final legacyAlarms = await _notificationsPlugin
          .pendingNotificationRequests();
      for (final alarm in legacyAlarms) {
        await _notificationsPlugin.cancel(alarm.id);
      }
    }
    _initialized = true;
  }

  Future<void> _persistMarkTakenAction(
    String medicationId,
    String scheduleId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kPendingActionKey,
      jsonEncode({
        'actionId': 'mark_taken',
        'payload': 'med:$medicationId|sched:$scheduleId',
      }),
    );
  }

  /// Requests the OS permissions required for an exact medication reminder.
  /// Android's exact-alarm access is granted in Settings rather than through
  /// the normal notification permission dialog.
  Future<bool> ensureAlarmPermissions() async {
    await _initialization;
    if (Platform.isAndroid) {
      final android = _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final notificationsAllowed =
          await android?.requestNotificationsPermission() ?? true;
      if (!notificationsAllowed) return false;

      final exactAllowed =
          await android?.requestExactAlarmsPermission() ??
          await android?.canScheduleExactNotifications() ??
          true;
      if (!exactAllowed) return false;

      final fullScreenAllowed =
          await _nativeAlarmChannel.invokeMethod<bool>(
            'ensureFullScreenAccess',
          ) ??
          true;
      if (!fullScreenAllowed) return false;

      return true;
    }

    if (Platform.isIOS) {
      final ios = _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      return await ios?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
            critical: true,
          ) ??
          true;
    }
    return true;
  }

  Future<void> openExactAlarmSettings() async {
    if (Platform.isIOS) {
      await openAppSettings();
      return;
    }
    if (!Platform.isAndroid) return;
    await _initialization;
    final android = _notificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final notificationsAllowed =
        await android?.requestNotificationsPermission() ?? true;
    if (!notificationsAllowed) {
      await openAppSettings();
      return;
    }
    await android?.requestExactAlarmsPermission();
  }

  /// A background action may have been persisted before the app came back to
  /// the foreground — resolve it now.
  Future<void> resolvePendingAction() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPendingActionKey);
    if (raw == null) return;
    await prefs.remove(_kPendingActionKey);
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      await _executeAction(
        data['actionId'] as String?,
        data['payload'] as String?,
      );
    } catch (_) {}
  }

  Future<void> _onNotificationTapped(NotificationResponse response) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPendingActionKey);
    if (raw != null) {
      if (_medicationProvider == null) return;
      await prefs.remove(_kPendingActionKey);
      try {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        await _executeAction(
          data['actionId'] as String?,
          data['payload'] as String?,
        );
        return;
      } catch (_) {}
    }
    // The app may still be wiring providers when a lock-screen action opens
    // it. Preserve the action until the startup resolver can process it.
    await prefs.setString(
      _kPendingActionKey,
      jsonEncode({'actionId': response.actionId, 'payload': response.payload}),
    );
    if (_medicationProvider == null) return;
    await prefs.remove(_kPendingActionKey);
    await _executeAction(response.actionId, response.payload);
  }

  Future<void> _executeAction(String? actionId, String? payload) async {
    final medId = _medIdFromPayload(payload);
    final scheduleId = _scheduleIdFromPayload(payload);

    if (actionId == 'mark_taken') {
      if (medId != null && scheduleId != null) {
        await dismissDoseAlarm(medicationId: medId, scheduleId: scheduleId);
        // The background isolate may have saved the action before the UI
        // restarted. Preserve that tap time when syncing it to the cloud.
        final savedTime = await DatabaseHelper().lastTakenAt(medId, scheduleId);
        final now = DateTime.now();
        final actionTime =
            savedTime != null &&
                savedTime.year == now.year &&
                savedTime.month == now.month &&
                savedTime.day == now.day
            ? savedTime
            : now;
        await _medicationProvider?.toggleDoseStatus(
          medId,
          scheduleId,
          true,
          recordedAt: actionTime,
        );
        await _medicationProvider?.loadMedications(forceRefresh: true);
      }
      return;
    }

    if (actionId == 'details' && medId != null && _router != null) {
      _router!.go('/medication/$medId');
    } else if (medId != null && scheduleId != null && _router != null) {
      _router!.go(
        '/alarm',
        extra: {'medicationId': medId, 'scheduleId': scheduleId},
      );
    } else if (_router != null) {
      _router!.go('/schedule');
    }
  }

  /// Pushes the ringing dose's alarm out by a few minutes without changing the
  /// medication schedule. Only Android has a native snooze to defer to.
  Future<void> snoozeMedicationAlarm({
    required String medicationId,
    required String scheduleId,
  }) async {
    await _initialization;
    if (!Platform.isAndroid) return;
    // Pass the same id the reminder was scheduled under, so the hash is not
    // reimplemented on the native side.
    await _nativeAlarmChannel.invokeMethod<void>('snoozeAlarm', {
      'id': safeNotificationId(scheduleId),
      'medicationId': medicationId,
      'scheduleId': scheduleId,
    });
  }

  Future<void> dismissDoseAlarm({
    required String medicationId,
    required String scheduleId,
  }) async {
    await _initialization;
    await _notificationsPlugin.cancel(safeNotificationId(scheduleId));
    if (Platform.isAndroid) {
      await _nativeAlarmChannel.invokeMethod<void>('stopRinging');
    }
    await _ttsProvider?.stop();
  }

  bool get isInitialized => _initialized;

  /// Ring a newly received guardian reminder while the patient app is active.
  Future<void> ringGuardianReminder({
    required String medicationId,
    required String scheduleId,
    required String medicationName,
    required String patientName,
  }) async {
    await _initialization;
    if (Platform.isAndroid) {
      await _nativeAlarmChannel.invokeMethod<void>('ringNow', {
        'id': safeNotificationId(scheduleId),
        'title': '$medicationName due now',
        'body': medicationAlarmMessage(
          name: patientName,
          medicineName: medicationName,
        ),
        'medicationId': medicationId,
        'scheduleId': scheduleId,
      });
    }
    _router?.go(
      '/alarm',
      extra: {'medicationId': medicationId, 'scheduleId': scheduleId},
    );
  }

  int safeNotificationId(String id) {
    // Hash the full schedule ID. Taking its first digits caused every dose
    // belonging to the same timestamp-based medication ID to collide.
    var hash = 0x811c9dc5;
    for (final codeUnit in id.codeUnits) {
      hash = ((hash ^ codeUnit) * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }

  String? _medIdFromPayload(String? payload) {
    if (payload == null) return null;
    final match = RegExp(r'med:([^|]+)').firstMatch(payload);
    return match?.group(1);
  }

  String? _scheduleIdFromPayload(String? payload) {
    if (payload == null) return null;
    final match = RegExp(r'sched:([^|]+)').firstMatch(payload);
    return match?.group(1);
  }

  Future<void> scheduleMedicationNotification({
    required int id,
    required String title,
    required String body,
    required TimeOfDay time,
    required String medicationId,
    required String scheduleId,
  }) async {
    // The provider is created before the Flutter notification plugin finishes
    // its platform initialization. Await it so the first saved medication is
    // never lost to an initialization race.
    await _initialization;
    if (Platform.isAndroid) {
      await _nativeAlarmChannel.invokeMethod<void>('scheduleAlarm', {
        'id': id,
        'title': title,
        'body': body,
        'medicationId': medicationId,
        'scheduleId': scheduleId,
        'hour': time.hour,
        'minute': time.minute,
      });
      return;
    }
    final now = DateTime.now();
    var scheduledDate = DateTime(
      now.year,
      now.month,
      now.day,
      time.hour,
      time.minute,
    );

    if (scheduledDate.isBefore(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }

    await _scheduleAt(
      id: id,
      title: title,
      body: body,
      at: scheduledDate,
      medicationId: medicationId,
      scheduleId: scheduleId,
    );
  }

  Future<void> synchronizeMedicationAlarms(
    List<Map<String, dynamic>> alarms,
  ) async {
    await _initialization;
    if (Platform.isAndroid) {
      await _nativeAlarmChannel.invokeMethod<void>('syncAlarms', {
        'alarms': alarms,
      });
      return;
    }
    for (final alarm in alarms) {
      await scheduleMedicationNotification(
        id: alarm['id'] as int,
        title: alarm['title'] as String,
        body: alarm['body'] as String,
        time: alarm['time'] as TimeOfDay,
        medicationId: alarm['medicationId'] as String,
        scheduleId: alarm['scheduleId'] as String,
      );
    }
  }

  Future<void> _scheduleAt({
    required int id,
    required String title,
    required String body,
    required DateTime at,
    required String medicationId,
    required String scheduleId,
    bool repeatsDaily = true,
  }) async {
    await _initialization;
    final payload = 'med:$medicationId|sched:$scheduleId';
    await _notificationsPlugin.zonedSchedule(
      id,
      title,
      body,
      tz.TZDateTime.from(at, tz.local),
      NotificationDetails(
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          interruptionLevel: InterruptionLevel.critical,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: payload,
      matchDateTimeComponents: repeatsDaily ? DateTimeComponents.time : null,
    );
  }

  Future<void> cancelNotification(int id) async {
    await _initialization;
    if (Platform.isAndroid) {
      await _nativeAlarmChannel.invokeMethod<void>('cancelAlarm', {'id': id});
    }
    await _notificationsPlugin.cancel(id);
  }

  Future<void> cancelAllMedicationAlarms() async {
    await _initialization;
    if (Platform.isAndroid) {
      await _nativeAlarmChannel.invokeMethod<void>('cancelAllAlarms');
    }
    await _notificationsPlugin.cancelAll();
  }
}
