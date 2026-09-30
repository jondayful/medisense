import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import 'supabase_service.dart';

/// Registers only a signed-in Guardian's current device for server-sent alerts.
/// The server always checks accepted pairings before addressing this token.
class GuardianPushService {
  String? _registeredGuardian;
  String? _registeredToken;
  String? _timeZonePatient;
  String? _timeZone;
  bool _firebaseReady = false;
  bool _listenersReady = false;
  Future<void> _work = Future<void>.value();
  StreamSubscription<String>? _tokenChanges;
  StreamSubscription<RemoteMessage>? _openedMessages;
  void Function()? onOpenGuardian;

  void sync({
    required String? userId,
    required bool isGuardian,
    required bool notificationsEnabled,
  }) {
    _work = _work.then((_) async {
      if (!SupabaseService.isConfigured ||
          SupabaseService.client.auth.currentUser?.id != userId) {
        await _unregister();
        return;
      }
      if (!isGuardian) {
        await _unregister();
        if (userId != null) await _syncPatientTimeZone(userId);
        return;
      }
      if (!notificationsEnabled) {
        await _unregister();
        return;
      }
      if (!Platform.isAndroid && !Platform.isIOS) return;
      try {
        if (_registeredGuardian != null && _registeredGuardian != userId) {
          await _unregister();
        }
        if (!_firebaseReady) {
          await Firebase.initializeApp();
          _firebaseReady = true;
        }
        _attachListeners();
        final messaging = FirebaseMessaging.instance;
        final permission = await messaging.requestPermission();
        if (permission.authorizationStatus != AuthorizationStatus.authorized &&
            permission.authorizationStatus != AuthorizationStatus.provisional) {
          await _unregister();
          return;
        }
        if (Platform.isIOS && await messaging.getAPNSToken() == null) return;
        final token = await messaging.getToken();
        if (token == null || userId == null) return;
        await _register(userId, token);
      } catch (error) {
        debugPrint('Guardian push registration unavailable: $error');
      }
    }).catchError((Object error) {
      debugPrint('Guardian push sync failed: $error');
    });
  }

  void _attachListeners() {
    if (_listenersReady) return;
    _listenersReady = true;
    _tokenChanges = FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      final guardian = _registeredGuardian;
      if (guardian != null &&
          SupabaseService.client.auth.currentUser?.id == guardian) {
        _work = _work.then((_) => _register(guardian, token)).catchError(
          (Object error) => debugPrint('Push token refresh failed: $error'),
        );
      }
    });
    _openedMessages = FirebaseMessaging.onMessageOpenedApp.listen((message) {
      if (message.data['route'] == 'guardian') onOpenGuardian?.call();
    });
    unawaited(FirebaseMessaging.instance.getInitialMessage().then((message) {
      if (message?.data['route'] == 'guardian') onOpenGuardian?.call();
    }));
  }

  Future<void> _register(String guardianId, String token) async {
    if (SupabaseService.client.auth.currentUser?.id != guardianId) return;
    if (_registeredGuardian == guardianId && _registeredToken == token) return;
    if (_registeredToken != null && _registeredToken != token) {
      await _deleteCloudToken(_registeredGuardian, _registeredToken);
    }
    await SupabaseService.client.from('guardian_push_tokens').upsert({
      'token': token,
      'guardian_id': guardianId,
      'platform': Platform.isIOS ? 'ios' : 'android',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).timeout(const Duration(seconds: 10));
    _registeredGuardian = guardianId;
    _registeredToken = token;
  }

  Future<void> _deleteCloudToken(String? guardianId, String? token) async {
    if (guardianId == null || token == null ||
        SupabaseService.client.auth.currentUser?.id != guardianId) {
      return;
    }
    try {
      await SupabaseService.client.from('guardian_push_tokens')
          .delete().eq('guardian_id', guardianId).eq('token', token)
          .timeout(const Duration(seconds: 10));
    } catch (error) {
      debugPrint('Push token cleanup will retry server-side: $error');
    }
  }

  Future<void> _unregister() async {
    final token = _registeredToken;
    if (token == null) return;
    await _deleteCloudToken(_registeredGuardian, token);
    _registeredToken = null;
    _registeredGuardian = null;
    if (_firebaseReady) {
      try {
        await FirebaseMessaging.instance.deleteToken();
      } catch (error) {
        debugPrint('Could not invalidate local push token: $error');
      }
    }
  }

  Future<void> _syncPatientTimeZone(String patientId) async {
    try {
      final zone = (await FlutterTimezone.getLocalTimezone()).identifier;
      if (zone == _timeZone && patientId == _timeZonePatient) return;
      final updated = await SupabaseService.client.from('profiles')
          .update({'time_zone': zone}).eq('id', patientId)
          .select('id').maybeSingle()
          .timeout(const Duration(seconds: 10));
      if (updated == null) return;
      _timeZone = zone;
      _timeZonePatient = patientId;
    } catch (error) {
      debugPrint('Could not sync patient time zone: $error');
    }
  }

  Future<void> dispose() async {
    await _tokenChanges?.cancel();
    await _openedMessages?.cancel();
  }
}
