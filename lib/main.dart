import 'dart:async';
// The primary camera package stays in the app API; Camera2 replaces only its
// Android platform implementation at startup.
// ignore: unused_import
import 'package:camera/camera.dart';
import 'package:camera_android/camera_android.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'app.dart';
import 'providers/medication_provider.dart';
import 'providers/app_state_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/notification_provider.dart';
import 'providers/tts_provider.dart';
import 'providers/voice_navigation_provider.dart';
import 'services/supabase_service.dart';
import 'services/medication_database_service.dart';
import 'services/medication_sync_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (defaultTargetPlatform == TargetPlatform.android) {
    CameraPlatform.instance = AndroidCamera();
  }

  final supabaseReady = await SupabaseService.initialize();
  debugPrint(
    supabaseReady ? 'Supabase connected' : 'Supabase is not configured',
  );

  // ponytail: don't block the first frame on permission prompts — the splash
  // stays up until every dialog is answered. Screens request what they need
  // at point of use (camera in MediScan, mic before listening).
  unawaited(_requestInitialPermissions());

  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  final appState = AppStateProvider();
  await appState.loadFromStorage();

  runApp(
    MultiProvider(
      providers: [
        Provider<MedicationSyncService>(
          lazy: false,
          create: (_) => MedicationSyncService(
            database: MedicationDatabaseService.instance,
            onError: (error, stack) =>
                debugPrint('Medication catalog sync: $error'),
          )..start(),
          dispose: (_, sync) {
            unawaited(
              sync
                  .dispose()
                  .whenComplete(sync.database.dispose)
                  .catchError(
                    (Object error) =>
                        debugPrint('Medication catalog shutdown: $error'),
                  ),
            );
          },
        ),
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => NotificationProvider()),
        ChangeNotifierProxyProvider2<
          NotificationProvider,
          AuthProvider,
          MedicationProvider
        >(
          create: (_) => MedicationProvider()..loadMedications(),
          update: (_, notifications, auth, medication) => medication!
            ..updateNotificationProvider(notifications)
            ..updateAppStateProvider(appState)
            ..updateUserId(auth.userId, isPatientAccount: auth.isPatient),
        ),
        ChangeNotifierProvider.value(value: appState),
        ChangeNotifierProvider(create: (_) => TtsProvider()),
        ChangeNotifierProxyProvider2<
          MedicationProvider,
          TtsProvider,
          VoiceNavigationProvider
        >(
          create: (_) => VoiceNavigationProvider(),
          update: (_, med, tts, voice) => voice!
            ..setMedicationProvider(med)
            ..setTtsProvider(tts),
        ),
      ],
      child: MediSenseApp(),
    ),
  );
}

Future<void> _requestInitialPermissions() async {
  await [
    Permission.camera,
    Permission.microphone,
    Permission.notification,
  ].request();
}
