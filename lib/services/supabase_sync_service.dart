import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/user.dart';
import 'supabase_service.dart';

class SupabaseSyncService {
  static final SupabaseSyncService _instance = SupabaseSyncService._();
  factory SupabaseSyncService() => _instance;
  SupabaseSyncService._();

  bool get isInitialized => SupabaseService.isConfigured;

  static final RegExp _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  /// Guest and legacy local IDs must never cross into Supabase UUID columns.
  static String? nullableUuid(String? value) {
    final normalized = value?.trim();
    return normalized != null && _uuid.hasMatch(normalized) ? normalized : null;
  }

  Future<T?> _withTimeout<T>(Future<T> Function() operation) async {
    if (!isInitialized) return null;
    try {
      return await operation().timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('SupabaseSync: operation failed - $e');
      return null;
    }
  }

  Future<bool> _withSyncStatus(Future<void> Function() operation) async {
    try {
      await operation().timeout(const Duration(seconds: 8));
      return true;
    } catch (error) {
      debugPrint('SupabaseSync: queued operation failed - $error');
      return false;
    }
  }

  Future<void> uploadUserProfile({
    required String userId,
    required String email,
    required String name,
    required UserRole role,
    String tier = 'Free',
    String passwordHash = '',
    String authProvider = 'password',
  }) async {
    if (!isInitialized) return;
    final uuid = nullableUuid(userId);
    if (uuid == null) return;
    // A local SQLite session is not a Supabase Auth session. Do not attempt a
    // Data API write unless the JWT belongs to this exact profile.
    final currentUser = SupabaseService.client.auth.currentUser;
    if (currentUser == null || currentUser.id != uuid) return;
    final existing = await _withTimeout(
      () => SupabaseService.client
          .from('profiles')
          .select('subscription_status, subscription_expires_at')
          .eq('id', uuid)
          .maybeSingle(),
    );
    final expiry = DateTime.tryParse(
      existing?['subscription_expires_at']?.toString() ?? '',
    );
    final subscriptionIsActive =
        existing?['subscription_status'] == 'active' &&
        expiry != null &&
        expiry.isAfter(DateTime.now().toUtc());
    final profile = <String, dynamic>{
      'id': uuid,
      'email': email,
      'name': name,
      'role': role.name,
      'auth_provider': authProvider,
      if (!subscriptionIsActive) 'tier': tier,
    };
    await _withTimeout(
      () => SupabaseService.client.from('profiles').upsert(profile),
    );
  }

  Future<bool> uploadMedication({
    required String patientId,
    required String medicationId,
    required Map<String, dynamic> data,
  }) async {
    final uuid = nullableUuid(patientId);
    if (uuid == null) return true;
    if (!isInitialized || SupabaseService.client.auth.currentUser?.id != uuid) {
      return false;
    }
    return _withSyncStatus(
      () => SupabaseService.client.from('medications').upsert({
        'id': medicationId,
        'patient_id': uuid,
        'data': data,
        'synced_at': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }

  Future<bool> deleteMedication({
    required String patientId,
    required String medicationId,
  }) async {
    final uuid = nullableUuid(patientId);
    if (uuid == null) return true;
    if (!isInitialized || SupabaseService.client.auth.currentUser?.id != uuid) {
      return false;
    }
    return _withSyncStatus(
      () => SupabaseService.client
          .from('medications')
          .delete()
          .eq('patient_id', uuid)
          .eq('id', medicationId),
    );
  }

  Future<bool> uploadAdherenceLog({
    required String patientId,
    required String logId,
    required Map<String, dynamic> data,
  }) async {
    final uuid = nullableUuid(patientId);
    if (uuid == null) return true;
    if (!isInitialized || SupabaseService.client.auth.currentUser?.id != uuid) {
      return false;
    }
    return _withSyncStatus(
      () => SupabaseService.client.from('adherence_logs').upsert({
        'id': logId,
        'patient_id': uuid,
        'data': data,
      }),
    );
  }

  Future<Map<String, dynamic>> sendPairingInvitation(
    String patientEmail,
  ) async {
    final currentUser = SupabaseService.client.auth.currentUser;
    if (currentUser == null) {
      throw StateError('Sign in to Supabase with the guardian account first.');
    }
    try {
      final response = await SupabaseService.client.functions
          .invoke(
            'create-pairing-request',
            body: {'patient_email': patientEmail.trim().toLowerCase()},
          )
          .timeout(const Duration(seconds: 20));
      final data = response.data;
      if (response.status < 200 || response.status >= 300) {
        final message = data is Map ? data['error']?.toString() : null;
        throw StateError(message ?? 'Could not send the invitation email.');
      }
      return parsePairingInvitationResponse(data);
    } on FunctionException catch (error) {
      debugPrint(
        'Pairing invitation function failed (${error.status}): ${error.details}',
      );
      final details = error.details;
      final message = details is Map ? details['error']?.toString() : null;
      throw StateError(message ?? 'Could not send the invitation email.');
    }
  }

  /// Older deployed functions return a pairing row after sending the email.
  /// Keep that response private and expose the same result as newer functions.
  @visibleForTesting
  static Map<String, dynamic> parsePairingInvitationResponse(dynamic data) {
    if (data is Map && data['status'] == 'request_processed') {
      return {'status': 'request_processed'};
    }
    final pairing = data is Map ? data['pairing'] : null;
    if (pairing is Map &&
        pairing['id'] is String &&
        (pairing['id'] as String).isNotEmpty &&
        pairing['status'] == 'pending') {
      return {'status': 'request_processed'};
    }
    throw StateError('The invitation service returned an invalid response.');
  }

  Future<void> updatePairingStatus(
    String pairingId,
    PairingStatus status, {
    required String patientId,
  }) async {
    final currentUser = SupabaseService.client.auth.currentUser;
    final patientUuid = nullableUuid(patientId);
    if (currentUser == null ||
        patientUuid == null ||
        currentUser.id != patientUuid) {
      throw StateError(
        'Sign in with the patient account to decide this invitation.',
      );
    }
    final updated = await SupabaseService.client
        .from('pairings')
        .update({'status': status.name})
        .eq('id', pairingId)
        .eq('patient_id', patientUuid)
        .eq('status', PairingStatus.pending.name)
        .select('id')
        .maybeSingle()
        .timeout(const Duration(seconds: 10));
    if (updated == null) {
      throw StateError(
        'This invitation is no longer pending. Refresh and try again.',
      );
    }
  }

  Future<List<Map<String, dynamic>>> fetchPatientMedications(
    String patientId,
  ) async {
    final uuid = nullableUuid(patientId);
    if (uuid == null) return const [];
    const pageSize = 500;
    final medications = <Map<String, dynamic>>[];
    for (var offset = 0; ; offset += pageSize) {
      final page = await SupabaseService.client
          .from('medications')
          .select('id, data')
          .eq('patient_id', uuid)
          .order('id')
          .range(offset, offset + pageSize - 1)
          .timeout(const Duration(seconds: 10));
      for (final row in page) {
        final data = Map<String, dynamic>.from(row['data'] as Map? ?? {});
        data['id'] = row['id'];
        medications.add(data);
      }
      if (page.length < pageSize) break;
    }
    return medications;
  }

  Future<List<Map<String, dynamic>>> fetchPatientLogs(String patientId) async {
    final uuid = nullableUuid(patientId);
    if (uuid == null) return const [];
    // PostgREST commonly caps a response at 1,000 rows. Page through the
    // patient's history so the seven-day graph cannot silently omit doses.
    const pageSize = 500;
    final logs = <Map<String, dynamic>>[];
    for (var offset = 0; ; offset += pageSize) {
      final page = await SupabaseService.client
          .from('adherence_logs')
          .select('id, data')
          .eq('patient_id', uuid)
          .order('id')
          .range(offset, offset + pageSize - 1)
          .timeout(const Duration(seconds: 10));
      for (final row in page) {
        final data = Map<String, dynamic>.from(row['data'] as Map? ?? {});
        data['id'] ??= row['id'];
        logs.add(data);
      }
      if (page.length < pageSize) break;
    }
    return logs;
  }

  /// Inserts a patient-addressed inbox reminder. RLS requires an accepted pair.
  Future<void> sendDoseReminder({
    required String patientId,
    required String medicationId,
    required String scheduleId,
  }) async {
    final patientUuid = nullableUuid(patientId);
    final guardianUuid = nullableUuid(
      SupabaseService.client.auth.currentUser?.id,
    );
    if (patientUuid == null || guardianUuid == null) {
      throw StateError('Sign in and connect with the patient first.');
    }
    await SupabaseService.client
        .from('care_reminders')
        .insert({
          'patient_id': patientUuid,
          'guardian_id': guardianUuid,
          'medication_id': medicationId,
          'schedule_id': scheduleId,
        })
        .timeout(const Duration(seconds: 10));
  }

  Future<List<Map<String, dynamic>>> fetchMyCareReminders(
    String patientId,
  ) async {
    final uuid = nullableUuid(patientId);
    if (uuid == null) return const [];
    final rows = await SupabaseService.client
        .from('care_reminders')
        .select('id, guardian_id, medication_id, schedule_id, created_at')
        .eq('patient_id', uuid)
        .order('created_at', ascending: false)
        .limit(5)
        .timeout(const Duration(seconds: 10));
    final reminders = rows
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    final names = <String, String>{};
    for (final reminder in reminders) {
      final guardianId = reminder['guardian_id']?.toString();
      if (guardianId == null || guardianId.isEmpty) continue;
      if (!names.containsKey(guardianId)) {
        final profile = await getUserProfile(guardianId);
        names[guardianId] = profile?['name']?.toString().trim() ?? 'Guardian';
      }
      reminder['guardian_name'] = names[guardianId];
    }
    return reminders;
  }

  /// Lightweight foreground check; only the visible card fetches names.
  Future<List<Map<String, dynamic>>> fetchRecentCareReminderIds(
    String patientId,
  ) async {
    final uuid = nullableUuid(patientId);
    if (uuid == null) return const [];
    final rows = await SupabaseService.client
        .from('care_reminders')
        .select('id, medication_id, schedule_id')
        .eq('patient_id', uuid)
        .order('created_at', ascending: false)
        .limit(10)
        .timeout(const Duration(seconds: 10));
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<List<PairingRecord>> fetchPairingRequests({
    required String userId,
    required String userEmail,
  }) async {
    final uuid = nullableUuid(userId);
    if (uuid == null) return const [];
    final currentUser = SupabaseService.client.auth.currentUser;
    if (currentUser?.id != uuid) {
      throw StateError('The active Supabase account does not match this user.');
    }
    final result = await SupabaseService.client
        .from('pairings')
        .select()
        .or('guardian_id.eq.$uuid,patient_id.eq.$uuid')
        .timeout(const Duration(seconds: 10));
    return result
        .map((row) => PairingRecord.fromDb(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<Map<String, dynamic>?> getUserProfile(String userId) async {
    final uuid = nullableUuid(userId);
    if (!isInitialized ||
        uuid == null ||
        SupabaseService.client.auth.currentUser?.id != uuid) {
      return null;
    }
    final result = await _withTimeout(
      () => SupabaseService.client
          .from('profiles')
          .select('id,email,name,role,tier,auth_provider')
          .eq('id', uuid)
          .maybeSingle(),
    );
    return result == null ? null : Map<String, dynamic>.from(result);
  }

  Future<String?> getPairedPatientName(String patientId) async {
    final uuid = nullableUuid(patientId);
    if (!isInitialized ||
        uuid == null ||
        SupabaseService.client.auth.currentUser == null) {
      return null;
    }
    try {
      final response = await SupabaseService.client.functions
          .invoke('patient-display-name', body: {'patient_id': uuid})
          .timeout(const Duration(seconds: 10));
      if (response.status < 200 || response.status >= 300) return null;
      final data = response.data;
      if (data is! Map) return null;
      final name = data['name']?.toString().trim();
      return name == null || name.isEmpty ? null : name;
    } catch (error) {
      debugPrint('SupabaseSync: patient name lookup failed - $error');
      return null;
    }
  }

  Future<Map<String, dynamic>?> findUserByEmail(String email) async {
    if (!isInitialized) return null;
    final currentUser = SupabaseService.client.auth.currentUser;
    if (currentUser == null ||
        currentUser.email?.toLowerCase() != email.toLowerCase()) {
      return null;
    }
    final result = await _withTimeout(
      () => SupabaseService.client
          .from('profiles')
          .select('id,email,name,role,tier,auth_provider')
          .eq('email', email.toLowerCase())
          .maybeSingle(),
    );
    return result == null ? null : Map<String, dynamic>.from(result);
  }

  Future<void> saveGoogleAccountRole({
    required String userId,
    required String email,
    required String name,
    required UserRole role,
  }) async {
    final currentUser = SupabaseService.client.auth.currentUser;
    final uuid = nullableUuid(userId);
    if (currentUser == null || uuid == null || currentUser.id != uuid) {
      throw StateError(
        'The active Google account does not match this profile.',
      );
    }
    await SupabaseService.client
        .from('profiles')
        .upsert({
          'id': uuid,
          'email': email,
          'name': name,
          'role': role.name,
          'auth_provider': 'google',
        })
        .select('id')
        .single()
        .timeout(const Duration(seconds: 10));
  }

  Future<void> acceptPairing({
    required String guardianId,
    required String patientId,
  }) async {
    // The accepted pairing row is the relationship source of truth. Keeping
    // it in one table avoids client-side writes to another user's profile.
  }

  Future<void> removePairing({
    required String guardianId,
    required String patientId,
  }) async {
    final guardianUuid = nullableUuid(guardianId);
    final patientUuid = nullableUuid(patientId);
    if (guardianUuid == null || patientUuid == null) return;
    await _withTimeout(
      () => SupabaseService.client
          .from('pairings')
          .delete()
          .eq('guardian_id', guardianUuid)
          .eq('patient_id', patientUuid),
    );
  }

  @Deprecated('Use Supabase Auth password reset links instead.')
  Future<void> storeResetCodeHash({
    required String email,
    required String codeHash,
  }) async {
    await _withTimeout(
      () => SupabaseService.client.from('password_resets').upsert({
        'email': email.toLowerCase(),
        'code_hash': codeHash,
        'expires_at': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 10))
            .toIso8601String(),
      }),
    );
  }

  @Deprecated('Use Supabase Auth password reset links instead.')
  Future<void> deleteResetCode({required String email}) async {
    await _withTimeout(
      () => SupabaseService.client
          .from('password_resets')
          .delete()
          .eq('email', email.toLowerCase()),
    );
  }

  @Deprecated('Use Supabase Auth password reset links instead.')
  Future<String?> getResetCodeHash({required String email}) async {
    final result = await _withTimeout(
      () => SupabaseService.client
          .from('password_resets')
          .select('code_hash, expires_at')
          .eq('email', email.toLowerCase())
          .maybeSingle(),
    );
    if (result == null) return null;
    final expiry = DateTime.tryParse(result['expires_at']?.toString() ?? '');
    if (expiry == null || expiry.isBefore(DateTime.now().toUtc())) return null;
    return result['code_hash'] as String?;
  }
}
