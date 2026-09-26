import 'package:supabase_flutter/supabase_flutter.dart';

/// Owns Supabase initialization and keeps credentials out of source control.
/// Run with --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
class SupabaseService {
  static const url = String.fromEnvironment('SUPABASE_URL');
  static const publishableKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const authCallbackUrl = 'medisense://auth/callback';
  static const passwordRecoveryUrl = 'medisense://auth/recovery';

  static bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;

  static SupabaseClient get client => Supabase.instance.client;

  static Future<bool> initialize() async {
    if (!isConfigured) return false;
    await Supabase.initialize(
      url: url,
      publishableKey: publishableKey,
      authOptions: FlutterAuthClientOptions(
        // The app exchanges recovery links itself so it can show a useful
        // message if a link has expired or has already been used.
        detectSessionInUriPredicate: (uri) =>
            uri.scheme == 'medisense' &&
            uri.host == 'auth' &&
            uri.path == '/callback',
      ),
    );
    return true;
  }
}
