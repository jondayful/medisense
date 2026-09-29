import 'package:shared_preferences/shared_preferences.dart';

/// Versioned consent prevents a disclosure change from silently preserving an
/// older choice to send potentially sensitive medicine-label images to Google.
class CloudOcrConsent {
  static const int version = 2;

  static bool isGranted(SharedPreferences preferences) =>
      preferences.getBool('cloudOcrConsent') == true &&
      preferences.getInt('cloudOcrConsentVersion') == version;

  static Future<void> save(SharedPreferences? preferences, bool granted) async {
    if (preferences == null) return;
    if (!granted) {
      await preferences.setBool('cloudOcrConsent', false);
      await preferences.remove('cloudOcrConsentVersion');
      return;
    }
    await preferences.setInt('cloudOcrConsentVersion', version);
    await preferences.setBool('cloudOcrConsent', true);
  }
}
