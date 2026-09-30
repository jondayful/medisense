import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme/app_theme.dart';
import 'models/accessibility_mode.dart';
import 'screens/dashboard_screen.dart';
import 'screens/mediscan_screen.dart';
import 'screens/medischedule_screen.dart';
import 'screens/medication_detail_screen.dart';
import 'screens/guardian_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/onboarding_setup_screen.dart';
import 'screens/alarm_alert_screen.dart';
import 'screens/legal_document_screen.dart';
import 'screens/payment_success_screen.dart';
import 'screens/password_recovery_screen.dart';
import 'screens/user_manual_screen.dart';
import 'providers/voice_navigation_provider.dart';
import 'providers/tts_provider.dart';
import 'providers/app_state_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/notification_provider.dart';
import 'providers/medication_provider.dart';
import 'services/supabase_sync_service.dart';
import 'services/supabase_service.dart';
import 'services/guardian_push_service.dart';

class MediSenseApp extends StatefulWidget {
  const MediSenseApp({super.key});

  @override
  State<MediSenseApp> createState() => _MediSenseAppState();
}

class _MediSenseAppState extends State<MediSenseApp>
    with WidgetsBindingObserver {
  late final GoRouter _router;
  late final AppLinks _appLinks;
  late final Future<void> _deepLinkReady;
  StreamSubscription<Uri>? _deepLinkSubscription;
  Future<void>? _wakeWordModelInitialization;
  bool _paymentDeepLinkReceived = false;
  bool _pairingDeepLinkReceived = false;
  bool _emailConfirmationLinkReceived = false;
  bool _passwordRecoveryLinkReceived = false;
  String? _lastRecoveryLink;
  AppStateProvider? _appStateProvider;
  AuthProvider? _authProvider;
  Timer? _careReminderTimer;
  String? _careReminderPatientId;
  bool _careReminderChecking = false;
  bool _careReminderForeground = true;
  final GuardianPushService _guardianPush = GuardianPushService();
  final List<String> _routeHistory = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Apply the persisted TTS speed and pitch once at startup (the sliders
    // otherwise only take effect after they are moved).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tts = context.read<TtsProvider>();
      final appState = context.read<AppStateProvider>();
      tts.setSpeechRate(appState.ttsSpeed);
      tts.setPitch(appState.ttsPitch);
      tts.setVolume(appState.ttsVolume);
    });

    _router = GoRouter(
      initialLocation: context.read<AppStateProvider>().onboardingSeen
          ? '/'
          : '/onboarding',
      routes: [
        GoRoute(
          path: '/auth',
          builder: (context, state) => _withBack(
            AuthScreen(
              emailConfirmed:
                  state.uri.queryParameters['emailConfirmed'] == 'true',
              pairingId: state.uri.queryParameters['pairingId'],
            ),
          ),
        ),
        GoRoute(
          path: '/reset-password',
          builder: (context, state) => _withBack(
            PasswordRecoveryScreen(
              status: state.uri.queryParameters['status'] ?? 'invalid',
            ),
          ),
        ),
        GoRoute(
          path: '/profile',
          builder: (context, state) => _withBack(const ProfileScreen()),
        ),
        GoRoute(
          path: '/accessibility-choice',
          builder: (context, state) => _withBack(const OnboardingSetupScreen()),
        ),
        GoRoute(
          path: '/onboarding',
          builder: (context, state) => _withBack(const OnboardingSetupScreen()),
        ),
        GoRoute(
          path: '/',
          builder: (context, state) => _withBack(const DashboardScreen()),
        ),
        GoRoute(
          path: '/scan',
          builder: (context, state) => _withBack(const MediScanScreen()),
        ),
        GoRoute(
          path: '/schedule',
          builder: (context, state) => _withBack(const MediScheduleScreen()),
        ),
        GoRoute(
          path: '/medication/:id',
          builder: (context, state) {
            final id = state.pathParameters['id']!;
            return _withBack(MedicationDetailScreen(medicationId: id));
          },
        ),
        GoRoute(
          path: '/guardian',
          builder: (context, state) => _withBack(const GuardianScreen()),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => _withBack(const SettingsScreen()),
        ),
        GoRoute(
          path: '/user-manual',
          builder: (context, state) => _withBack(const UserManualScreen()),
        ),
        GoRoute(
          path: '/terms',
          builder: (context, state) => _withBack(
            const LegalDocumentScreen(type: LegalDocumentType.terms),
          ),
        ),
        GoRoute(
          path: '/privacy',
          builder: (context, state) => _withBack(
            const LegalDocumentScreen(type: LegalDocumentType.privacy),
          ),
        ),
        GoRoute(
          path: '/payment-success',
          builder: (context, state) => _withBack(const PaymentSuccessScreen()),
        ),
        GoRoute(
          path: '/alarm',
          builder: (context, state) {
            final extra = state.extra is Map
                ? state.extra as Map
                : const <String, dynamic>{};
            return _withBack(
              AlarmAlertScreen(
                medicationId: extra['medicationId'] as String? ?? '',
                scheduleId: extra['scheduleId'] as String? ?? '',
              ),
            );
          },
        ),
      ],
    );

    _router.routerDelegate.addListener(_onRouteChanged);
    _guardianPush.onOpenGuardian = () {
      if (mounted) _router.go('/guardian');
    };
    _deepLinkReady = _setupDeepLinks();
    unawaited(_deepLinkReady);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Wait until the initial link has been checked before restoring the
      // previous route. Otherwise a cold-start payment callback can be
      // immediately replaced by the saved route.
      await _deepLinkReady;
      if (!mounted) return;
      final voiceProvider = context.read<VoiceNavigationProvider>();
      final ttsProvider = context.read<TtsProvider>();
      final appState = context.read<AppStateProvider>();
      final auth = context.read<AuthProvider>();
      final notifProvider = context.read<NotificationProvider>();
      final medProvider = context.read<MedicationProvider>();
      voiceProvider.setRouter(_router);
      voiceProvider.setTtsProvider(ttsProvider);
      voiceProvider.setAppStateProvider(appState);
      notifProvider.setRouter(_router);
      notifProvider.setMedicationProvider(medProvider);
      notifProvider.setTtsProvider(ttsProvider);

      // SharedPreferences can remember a local app login after Supabase has
      // no session. Do not restore that identity as an authenticated account.
      if (SupabaseService.isConfigured &&
          SupabaseService.client.auth.currentUser?.id != appState.savedUserId) {
        await appState.clearAuthSession();
      }

      if (appState.savedUserId != null && appState.savedUserEmail != null) {
        final syncService = SupabaseSyncService();
        final profile = await syncService.getUserProfile(appState.savedUserId!);
        final profileRole = profile?['role'] as String?;
        final restoredRole =
            profileRole == 'guardian' || profileRole == 'patient'
            ? profileRole!
            : appState.savedRole ?? 'patient';
        auth.login(
          appState.savedUserId!,
          appState.savedUserName ?? 'User',
          appState.savedUserEmail!,
          tier: appState.savedTier ?? 'Free',
          role: restoredRole,
        );
        final profileData = profile;
        if (profileData != null) {
          final expiry = profileData['subscription_expires_at'];
          final expiryDate = expiry is DateTime
              ? expiry
              : DateTime.tryParse(expiry?.toString() ?? '');
          final active =
              profileData['subscription_status'] == 'active' &&
              expiryDate != null &&
              expiryDate.isAfter(DateTime.now());
          final restoredTier = active
              ? (profileData['tier'] as String? ?? 'Free')
              : 'Free';
          auth.updateTier(restoredTier);
          await appState.saveAuthSession(
            auth.userId,
            auth.userName,
            auth.userEmail,
            restoredTier,
            role: auth.role.name,
          );
        }
        // The profile write is maintenance work; route restoration and local
        // reminders should not wait for another network round trip.
        unawaited(
          syncService
              .uploadUserProfile(
                userId: auth.userId,
                email: auth.userEmail,
                name: auth.userName,
                role: auth.role,
                tier: auth.tier,
              )
              .catchError((Object error, StackTrace stack) {
                debugPrint('Could not refresh profile on startup: $error');
              }),
        );
      }

      // Notification actions refer to medication IDs in the restored user's
      // local database. Attach that identity before resolving a cold-start tap.
      medProvider.updateUserId(auth.userId, isPatientAccount: auth.isPatient);
      await notifProvider.resolvePendingAction();

      if (!mounted) return;
      if (!_paymentDeepLinkReceived &&
          !_pairingDeepLinkReceived &&
          !_emailConfirmationLinkReceived &&
          !_passwordRecoveryLinkReceived) {
        if (appState.onboardingSeen) {
          final savedRoute = appState.lastRoute;
          if (savedRoute != null && savedRoute.isNotEmpty) {
            _router.go(savedRoute);
          }
        } else {
          _router.go('/onboarding');
        }
      }
      if (appState.onboardingSeen) {
        _syncVoiceNavigationMode();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextAppState = context.read<AppStateProvider>();
    if (_appStateProvider == nextAppState) return;

    _appStateProvider?.removeListener(_syncVoiceNavigationMode);
    _appStateProvider?.removeListener(_syncCloudNotifications);
    _appStateProvider = nextAppState;
    _appStateProvider?.addListener(_syncVoiceNavigationMode);
    _appStateProvider?.addListener(_syncCloudNotifications);
    final nextAuth = context.read<AuthProvider>();
    if (_authProvider != nextAuth) {
      _authProvider?.removeListener(_syncCareReminderPolling);
      _authProvider?.removeListener(_syncCloudNotifications);
      _authProvider = nextAuth;
      _authProvider?.addListener(_syncCareReminderPolling);
      _authProvider?.addListener(_syncCloudNotifications);
      _syncCareReminderPolling();
      _syncCloudNotifications();
    }
  }

  @override
  void dispose() {
    unawaited(_deepLinkSubscription?.cancel() ?? Future<void>.value());
    _appStateProvider?.removeListener(_syncVoiceNavigationMode);
    _appStateProvider?.removeListener(_syncCloudNotifications);
    _authProvider?.removeListener(_syncCareReminderPolling);
    _authProvider?.removeListener(_syncCloudNotifications);
    _careReminderTimer?.cancel();
    unawaited(_guardianPush.dispose());
    _router.routerDelegate.removeListener(_onRouteChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _setupDeepLinks() async {
    _appLinks = AppLinks();
    // The mobile stream also includes the launch link. Subscribe first, then
    // bound the platform's initial-link lookup so session restore can proceed.
    _deepLinkSubscription = _appLinks.uriLinkStream.listen(
      _handleDeepLink,
      onError: (Object error, StackTrace stack) =>
          debugPrint('Deep link listener failed: $error'),
    );
    try {
      final initialLink = await _appLinks.getInitialLink().timeout(
        const Duration(seconds: 3),
      );
      if (initialLink != null) _handleDeepLink(initialLink);
    } catch (error) {
      debugPrint('Initial deep link unavailable: $error');
    }
  }

  void _handleDeepLink(Uri uri) {
    if (uri.scheme == 'medisense' &&
        uri.host == 'pairing' &&
        uri.path == '/invitation') {
      _pairingDeepLinkReceived = true;
      final pairingId = uri.queryParameters['pairing_id']?.trim();
      if (pairingId == null || pairingId.isEmpty) return;
      unawaited(
        context.read<AppStateProvider>().setPendingPairingId(pairingId),
      );
      final signedIn =
          SupabaseService.isConfigured &&
          SupabaseService.client.auth.currentUser != null;
      if (mounted) {
        _router.go(
          signedIn
              ? '/guardian?pairingId=${Uri.encodeQueryComponent(pairingId)}'
              : '/auth?pairingId=${Uri.encodeQueryComponent(pairingId)}',
        );
      }
      return;
    }
    if (uri.scheme == 'medisense' &&
        uri.host == 'auth' &&
        uri.path == '/recovery') {
      final link = uri.toString();
      if (_lastRecoveryLink == link) return;
      _lastRecoveryLink = link;
      _passwordRecoveryLinkReceived = true;
      _router.go('/reset-password?status=checking');
      unawaited(_openRecoveryLink(uri));
      return;
    }
    if (uri.scheme == 'medisense' &&
        uri.host == 'auth' &&
        uri.path == '/callback') {
      _emailConfirmationLinkReceived = true;
      if (mounted) _router.go('/auth?emailConfirmed=true');
      return;
    }
    if (uri.scheme == 'medisense' &&
        uri.host == 'payment' &&
        uri.path == '/success') {
      _paymentDeepLinkReceived = true;
      if (!mounted) return;
      _router.go('/payment-success');
    }
  }

  Future<void> _openRecoveryLink(Uri uri) async {
    try {
      if (!SupabaseService.isConfigured) throw StateError('Auth unavailable');
      final result = await SupabaseService.client.auth.getSessionFromUrl(uri);
      if (!mounted || result.session.user.id.isEmpty) return;
      _router.go('/reset-password?status=ready');
    } catch (error) {
      debugPrint('Password recovery link could not be opened: $error');
      if (mounted) _router.go('/reset-password?status=invalid');
    }
  }

  void _syncVoiceNavigationMode() {
    if (!mounted) return;
    final appState = context.read<AppStateProvider>();
    final voiceProvider = context.read<VoiceNavigationProvider>();
    final shouldUseVoiceNavigation = appState.voiceNavigationEnabled;

    voiceProvider.setPushToTalkMode(shouldUseVoiceNavigation);
    if (shouldUseVoiceNavigation) {
      _initializeInstalledWakeWordModel(voiceProvider);
    }
  }

  void _syncCareReminderPolling() {
    if (!mounted) return;
    final auth = _authProvider;
    final patientId =
        auth != null &&
            auth.isLoggedIn &&
            auth.isPatient &&
            SupabaseService.isConfigured &&
            _careReminderForeground
        ? auth.userId
        : null;
    if (patientId == _careReminderPatientId && _careReminderTimer != null) {
      return;
    }
    _careReminderTimer?.cancel();
    _careReminderTimer = null;
    _careReminderPatientId = patientId;
    if (patientId == null) return;
    unawaited(_checkCareReminders(patientId));
    _careReminderTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_checkCareReminders(patientId));
    });
  }

  void _syncCloudNotifications() {
    final auth = _authProvider;
    _guardianPush.sync(
      userId: auth?.isLoggedIn == true ? auth!.userId : null,
      isGuardian: auth?.isGuardian == true,
      notificationsEnabled: _appStateProvider?.notificationsEnabled ?? true,
    );
  }

  Future<void> _checkCareReminders(String patientId) async {
    if (_careReminderChecking ||
        !mounted ||
        _careReminderPatientId != patientId) {
      return;
    }
    _careReminderChecking = true;
    try {
      final rows = await SupabaseSyncService().fetchRecentCareReminderIds(
        patientId,
      );
      if (!mounted || _careReminderPatientId != patientId) return;
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || _careReminderPatientId != patientId) return;
      final key = 'seen_care_reminders_$patientId';
      final previous = prefs.getStringList(key);
      final ids = rows.map((row) => row['id'].toString()).toList();
      if (previous != null) {
        final seen = previous.toSet();
        final fresh = rows.where((row) => !seen.contains(row['id'].toString()));
        if (fresh.isNotEmpty &&
            context.read<AppStateProvider>().notificationsEnabled) {
          final reminder = fresh.first;
          final medId = reminder['medication_id']?.toString();
          final scheduleId = reminder['schedule_id']?.toString();
          final meds = context.read<MedicationProvider>();
          var medication = medId == null ? null : meds.getById(medId);
          if (medication == null) {
            await meds.loadMedications(forceRefresh: true);
            if (!mounted || _careReminderPatientId != patientId) return;
            medication = medId == null ? null : meds.getById(medId);
          }
          if (medication != null &&
              medId != null &&
              scheduleId != null &&
              mounted) {
            await context.read<NotificationProvider>().ringGuardianReminder(
              medicationId: medId,
              scheduleId: scheduleId,
              medicationName: medication.name,
              patientName: _authProvider?.userName ?? 'kaibigan',
            );
          }
        }
      }
      await prefs.setStringList(key, {...ids, ...?previous}.take(50).toList());
    } catch (error) {
      debugPrint('Care reminder check failed: $error');
    } finally {
      _careReminderChecking = false;
    }
  }

  void _initializeInstalledWakeWordModel(VoiceNavigationProvider voice) {
    if (voice.isVoskInitialized || _wakeWordModelInitialization != null) {
      return;
    }
    final initialization = () async {
      try {
        // Wake-word recognition must be armed before the user taps the mic.
        // Only load an existing model here; the mic flow remains responsible
        // for presenting the download and storage prompts on first use.
        final modelPath = await voice.voskModelStore.installedModelPath();
        if (!mounted ||
            modelPath == null ||
            !context.read<AppStateProvider>().voiceNavigationEnabled) {
          return;
        }
        await voice.initializeVosk(modelPath);
      } catch (error, stackTrace) {
        debugPrint(
          'Wake-word listener could not initialize: $error\n$stackTrace',
        );
      }
    }();
    _wakeWordModelInitialization = initialization;
    unawaited(
      initialization.whenComplete(() {
        if (identical(_wakeWordModelInitialization, initialization)) {
          _wakeWordModelInitialization = null;
        }
      }),
    );
  }

  void _onRouteChanged() {
    try {
      final location = _router.routerDelegate.currentConfiguration.uri
          .toString();
      if (location.startsWith('/reset-password')) return;
      if (location.isNotEmpty) {
        final isNewRoute =
            _routeHistory.isEmpty || _routeHistory.last != location;
        if (isNewRoute) {
          _routeHistory.add(location);
          if (_routeHistory.length > 30) _routeHistory.removeAt(0);
          final path = _router.routerDelegate.currentConfiguration.uri.path;
          if (path != '/' &&
              path != '/scan' &&
              path != '/schedule' &&
              path != '/alarm') {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                context.read<VoiceNavigationProvider>().announceScreen(path);
              }
            });
          }
        }
        if (!location.startsWith('/alarm')) {
          final appState = context.read<AppStateProvider>();
          appState.saveLastRoute(location);
        }
      }
    } catch (_) {}
  }

  Future<bool> _handleSystemBack() async {
    if (_router.canPop()) {
      _router.pop();
      return true;
    }
    if (_routeHistory.length > 1) {
      _routeHistory.removeLast();
      _router.go(_routeHistory.last);
      return true;
    }
    final current = _router.routerDelegate.currentConfiguration.uri.path;
    if (current != '/') {
      _router.go('/');
      return true;
    }
    return false;
  }

  Widget _withBack(Widget screen) => Builder(
    builder: (routeContext) => BackButtonListener(
      onBackButtonPressed: () {
        final navigator = Navigator.of(routeContext);
        if (navigator.canPop() && !_router.canPop()) {
          navigator.pop();
          return Future<bool>.value(true);
        }
        return _handleSystemBack();
      },
      child: screen,
    ),
  );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _careReminderForeground = state == AppLifecycleState.resumed;
    _syncCareReminderPolling();
    if (_careReminderForeground) _syncCloudNotifications();
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      try {
        final appState = context.read<AppStateProvider>();
        final location = _router.routerDelegate.currentConfiguration.uri.path;
        if (location.isNotEmpty && location != '/alarm') {
          appState.saveLastRoute(location);
        }
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final isVisionLoss = appState.accessibilityMode.isVisionLoss;
    final isElder = appState.accessibilityMode.isElder;
    final usesElderTheme = isElder || isVisionLoss;
    Widget app = MaterialApp.router(
      title: 'MediSense',
      debugShowCheckedModeBanner: false,
      theme: usesElderTheme ? AppTheme.elderLightTheme : AppTheme.lightTheme,
      darkTheme: usesElderTheme ? AppTheme.elderDarkTheme : AppTheme.darkTheme,
      themeMode: appState.darkMode ? ThemeMode.dark : ThemeMode.light,
      routerConfig: _router,
      // The capsule navigation owns the optional centered microphone. This
      // keeps it out of Settings and prevents it from covering form controls.
      builder: (context, child) => child!,
    );

    // ponytail: no extra textScaler for elder mode — the elder themes are
    // already sized up; scaling them again (old 1.35x) overflowed every card.
    return app;
  }
}
