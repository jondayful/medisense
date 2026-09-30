import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/accessibility_mode.dart';
import '../models/voice_levels.dart';
import '../services/cloud_ocr_consent.dart';

enum TtsVerbosity { essential, standard, detailed }

extension TtsVerbosityX on TtsVerbosity {
  String get label {
    switch (this) {
      case TtsVerbosity.essential:
        return 'Essential';
      case TtsVerbosity.standard:
        return 'Standard';
      case TtsVerbosity.detailed:
        return 'Detailed';
    }
  }

  static TtsVerbosity fromString(String value) {
    return TtsVerbosity.values.firstWhere(
      (v) => v.name == value,
      orElse: () => TtsVerbosity.standard,
    );
  }
}

class AppStateProvider extends ChangeNotifier {
  SharedPreferences? _prefs;
  bool _onboardingSeen = false;
  bool _isFilipino = false;
  bool _notificationsEnabled = true;
  bool _darkMode = false;
  bool _voiceNavigationEnabled = false;
  bool _micTutorialShown = false;
  bool _wifiOnlyDownloads = false;
  bool _cloudOcrConsent = false;
  double _ttsSpeed = 1.0;
  double _ttsPitch = 1.0;
  double _ttsVolume = 1.0;
  TtsVerbosity _ttsVerbosity = TtsVerbosity.standard;
  String? _onboardingName;
  String? _lastRoute;
  AccessibilityMode _accessibilityMode = AccessibilityMode.none;

  String? _authUserId;
  String? _authUserName;
  String? _authUserEmail;
  String? _authTier;
  String? _authRole;
  String? _pendingPairingId;

  bool get onboardingSeen => _onboardingSeen;
  bool get isFilipino => _isFilipino;
  bool get notificationsEnabled => _notificationsEnabled;
  bool get darkMode => _darkMode;
  bool get voiceNavigationEnabled => _voiceNavigationEnabled;
  bool get micTutorialShown => _micTutorialShown;
  bool get wifiOnlyDownloads => _wifiOnlyDownloads;
  bool get cloudOcrConsent => _cloudOcrConsent;
  double get ttsSpeed => _ttsSpeed;
  double get ttsPitch => _ttsPitch;
  double get ttsVolume => _ttsVolume;
  TtsVerbosity get ttsVerbosity => _ttsVerbosity;
  String get languageCode => _isFilipino ? 'fil' : 'en';
  String get languageLabel => _isFilipino ? 'Filipino' : 'English';
  String? get lastRoute => _lastRoute;
  AccessibilityMode get accessibilityMode => _accessibilityMode;
  String? get onboardingName => _onboardingName;

  String? get savedUserId => _authUserId;
  String? get savedUserName => _authUserName;
  String? get savedUserEmail => _authUserEmail;
  String? get savedTier => _authTier;
  String? get savedRole => _authRole;
  String? get pendingPairingId => _pendingPairingId;

  Future<void> loadFromStorage() async {
    _prefs = await SharedPreferences.getInstance();
    final firstLaunch = _prefs!.getBool('is_first_launch');
    final storedOnboardingSeen = _prefs!.getBool('onboardingSeen');
    _onboardingSeen = firstLaunch == true
        ? false
        : (storedOnboardingSeen ?? firstLaunch == false);
    final locales = WidgetsBinding.instance.platformDispatcher.locales;
    final deviceLanguage = locales.isEmpty ? '' : locales.first.languageCode;
    _isFilipino =
        _prefs!.getBool('isFilipino') ??
        (deviceLanguage == 'fil' || deviceLanguage == 'tl');
    _notificationsEnabled = _prefs!.getBool('notificationsEnabled') ?? true;
    _darkMode = _prefs!.getBool('darkMode') ?? false;
    _ttsSpeed = VoiceLevels.valueFor(
      VoiceLevels.levelFor(
        _prefs!.getDouble('ttsSpeed') ?? 1.0,
        VoiceLevels.speed,
      ),
      VoiceLevels.speed,
    );
    _ttsPitch = VoiceLevels.valueFor(
      VoiceLevels.levelFor(
        _prefs!.getDouble('ttsPitch') ?? 1.0,
        VoiceLevels.pitch,
      ),
      VoiceLevels.pitch,
    );
    _ttsVolume = VoiceLevels.valueFor(
      VoiceLevels.levelFor(
        _prefs!.getDouble('ttsVolume') ?? 1.0,
        VoiceLevels.volume,
      ),
      VoiceLevels.volume,
    );
    _ttsVerbosity = TtsVerbosityX.fromString(
      _prefs!.getString('ttsVerbosity') ?? '',
    );
    _onboardingName = _prefs!.getString('onboardingName');
    _micTutorialShown = _prefs!.getBool('micTutorialShown') ?? false;
    _wifiOnlyDownloads = _prefs!.getBool('wifiOnlyDownloads') ?? false;
    // Older builds had a single switch without the current disclosure dialog.
    // Require a fresh choice before any later cloud image transfer.
    _cloudOcrConsent = CloudOcrConsent.isGranted(_prefs!);
    _lastRoute = _prefs!.getString('lastRoute');
    _authUserId = _prefs!.getString('authUserId');
    _authUserName = _prefs!.getString('authUserName');
    _authUserEmail = _prefs!.getString('authUserEmail');
    _authTier = _prefs!.getString('authTier');
    _authRole = _prefs!.getString('authRole');
    _pendingPairingId = _prefs!.getString('pendingPairingId');
    final modeStr = _prefs!.getString(AccessibilityMode.none.storageKey);
    _accessibilityMode = modeStr != null
        ? AccessibilityModeX.fromString(modeStr)
        : AccessibilityMode.none;
    _voiceNavigationEnabled =
        _prefs!.getBool('voiceNavigationEnabled') ??
        _accessibilityMode.isVisionLoss;
    notifyListeners();
  }

  Future<void> saveAuthSession(
    String id,
    String name,
    String email,
    String tier, {
    String role = 'patient',
  }) async {
    if (_authUserId != id) {
      _cloudOcrConsent = false;
      await _prefs?.setBool('cloudOcrConsent', false);
      notifyListeners();
    }
    _authUserId = id;
    _authUserName = name;
    _authUserEmail = email;
    _authTier = tier;
    _authRole = role;
    await _prefs?.setString('authUserId', id);
    await _prefs?.setString('authUserName', name);
    await _prefs?.setString('authUserEmail', email);
    await _prefs?.setString('authTier', tier);
    await _prefs?.setString('authRole', role);
  }

  Future<void> clearAuthSession() async {
    _cloudOcrConsent = false;
    await _prefs?.setBool('cloudOcrConsent', false);
    notifyListeners();
    _authUserId = null;
    _authUserName = null;
    _authUserEmail = null;
    _authTier = null;
    _authRole = null;
    await _prefs?.remove('authUserId');
    await _prefs?.remove('authUserName');
    await _prefs?.remove('authUserEmail');
    await _prefs?.remove('authTier');
    await _prefs?.remove('authRole');
  }

  Future<void> setPendingPairingId(String? pairingId) async {
    final normalized = pairingId?.trim();
    _pendingPairingId = normalized == null || normalized.isEmpty
        ? null
        : normalized;
    if (_pendingPairingId == null) {
      await _prefs?.remove('pendingPairingId');
    } else {
      await _prefs?.setString('pendingPairingId', _pendingPairingId!);
    }
  }

  Future<void> _saveBool(String key, bool value) async {
    await _prefs?.setBool(key, value);
  }

  Future<void> _saveDouble(String key, double value) async {
    await _prefs?.setDouble(key, value);
  }

  Future<void> _saveString(String key, String value) async {
    await _prefs?.setString(key, value);
  }

  void saveLastRoute(String route) {
    _lastRoute = route;
    _saveString('lastRoute', route);
  }

  void completeOnboarding() {
    _onboardingSeen = true;
    _saveBool('onboardingSeen', true);
    _saveBool('is_first_launch', false);
    notifyListeners();
  }

  Future<void> setOnboardingName(String name) async {
    final value = name.trim();
    _onboardingName = value.isEmpty ? null : value;
    if (value.isEmpty) {
      await _prefs?.remove('onboardingName');
    } else {
      await _prefs?.setString('onboardingName', value);
    }
    notifyListeners();
  }

  Future<void> setAccessibilityMode(AccessibilityMode mode) async {
    _accessibilityMode = mode;
    // Vision Loss is an audio-first experience, so selecting it enables voice
    // navigation. Keep the two preferences independent in the other direction:
    // changing away from Vision Loss must not silently disable voice navigation.
    final enableVoiceNavigation = mode.isVisionLoss && !_voiceNavigationEnabled;
    if (enableVoiceNavigation) {
      _voiceNavigationEnabled = true;
    }
    notifyListeners();
    await _saveString(mode.storageKey, mode.persistedValue);
    if (enableVoiceNavigation) {
      await _saveBool('voiceNavigationEnabled', true);
    }
  }

  void toggleLanguage() {
    setFilipino(!_isFilipino);
  }

  void setFilipino(bool enabled) {
    if (_isFilipino == enabled) return;
    _isFilipino = enabled;
    _saveBool('isFilipino', _isFilipino);
    notifyListeners();
  }

  void toggleNotifications() {
    _notificationsEnabled = !_notificationsEnabled;
    _saveBool('notificationsEnabled', _notificationsEnabled);
    notifyListeners();
  }

  void toggleDarkMode() {
    _darkMode = !_darkMode;
    _saveBool('darkMode', _darkMode);
    notifyListeners();
  }

  void setVoiceNavigationEnabled(bool enabled) {
    _voiceNavigationEnabled = enabled;
    _saveBool('voiceNavigationEnabled', enabled);
    notifyListeners();
  }

  void markMicTutorialShown() {
    if (_micTutorialShown) return;
    _micTutorialShown = true;
    _saveBool('micTutorialShown', true);
  }

  void setWifiOnlyDownloads(bool value) {
    _wifiOnlyDownloads = value;
    _saveBool('wifiOnlyDownloads', value);
    notifyListeners();
  }

  Future<void> setCloudOcrConsent(bool value) async {
    await CloudOcrConsent.save(_prefs, value);
    _cloudOcrConsent = value;
    notifyListeners();
  }

  void setTtsSpeed(double speed) {
    _ttsSpeed = VoiceLevels.valueFor(
      VoiceLevels.levelFor(speed, VoiceLevels.speed),
      VoiceLevels.speed,
    );
    _saveDouble('ttsSpeed', _ttsSpeed);
    notifyListeners();
  }

  void setTtsPitch(double pitch) {
    _ttsPitch = VoiceLevels.valueFor(
      VoiceLevels.levelFor(pitch, VoiceLevels.pitch),
      VoiceLevels.pitch,
    );
    _saveDouble('ttsPitch', _ttsPitch);
    notifyListeners();
  }

  void setTtsVolume(double volume) {
    _ttsVolume = VoiceLevels.valueFor(
      VoiceLevels.levelFor(volume, VoiceLevels.volume),
      VoiceLevels.volume,
    );
    _saveDouble('ttsVolume', _ttsVolume);
    notifyListeners();
  }

  void setTtsVerbosity(TtsVerbosity verbosity) {
    if (_ttsVerbosity == verbosity) return;
    _ttsVerbosity = verbosity;
    _saveString('ttsVerbosity', verbosity.name);
    notifyListeners();
  }
}
