import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../providers/auth_provider.dart';
import '../providers/app_state_provider.dart';
import '../models/accessibility_mode.dart';
import '../models/user.dart';
import '../data/database_helper.dart';
import '../services/supabase_sync_service.dart';
import '../services/supabase_service.dart';
import '../services/password_hasher.dart';
import '../services/password_rules.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, this.emailConfirmed = false, this.pairingId});

  final bool emailConfirmed;
  final String? pairingId;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  static const _googleServerClientId =
      '667948555890-obght55e2oc8g3klgas96iqudsa34s37.apps.googleusercontent.com';
  bool _isLogin = true;
  bool _emailStep = true;
  bool _checkingEmail = false;
  bool _showPassword = false;
  bool _passwordFocused = false;
  final _formKey = GlobalKey<FormState>();
  UserRole _selectedRole = UserRole.patient;

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _passwordFocusNode = FocusNode();
  final _passwordRequirementsKey = GlobalKey();
  Future<void>? _googleInitialization;

  String get _fullName => [
    _firstNameController.text.trim(),
    _lastNameController.text.trim(),
  ].where((part) => part.isNotEmpty).join(' ');

  bool _hasMinimumPasswordLength(String value) =>
      PasswordRules.hasLength(value);
  bool _hasUppercase(String value) => PasswordRules.hasUppercase(value);
  bool _hasLowercase(String value) => PasswordRules.hasLowercase(value);
  bool _hasNumber(String value) => PasswordRules.hasNumber(value);
  bool _hasSpecialCharacter(String value) => PasswordRules.hasSymbol(value);

  String? _validatePassword(String? value) {
    final password = value ?? '';
    if (password.isEmpty) return 'Please enter a password';
    if (_isLogin) return null;
    if (!_hasMinimumPasswordLength(password) ||
        !_hasUppercase(password) ||
        !_hasLowercase(password) ||
        !_hasNumber(password) ||
        !_hasSpecialCharacter(password)) {
      return 'Complete all password requirements';
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _passwordFocusNode.addListener(_handlePasswordFocusChange);
    if (widget.emailConfirmed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Email confirmed. Sign in to continue.'),
            backgroundColor: AppTheme.success,
          ),
        );
      });
    }
  }

  void _handlePasswordFocusChange() {
    if (!mounted || _passwordFocused == _passwordFocusNode.hasFocus) return;
    final focused = _passwordFocusNode.hasFocus;
    setState(() => _passwordFocused = focused);
    if (focused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future<void>.delayed(const Duration(milliseconds: 300), () {
          if (!mounted || !_passwordFocusNode.hasFocus) return;
          final requirementsContext = _passwordRequirementsKey.currentContext;
          if (requirementsContext == null || !requirementsContext.mounted) {
            return;
          }
          Scrollable.ensureVisible(
            requirementsContext,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            alignment: 0.25,
          );
        });
      });
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _passwordFocusNode
      ..removeListener(_handlePasswordFocusChange)
      ..dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final db = DatabaseHelper();
    final auth = context.read<AuthProvider>();
    final appState = context.read<AppStateProvider>();
    final email = _emailController.text.trim().toLowerCase();
    final password = _passwordController.text;

    if (_isLogin && SupabaseService.isConfigured) {
      var credentialsAccepted = false;
      try {
        final response = await SupabaseService.client.auth.signInWithPassword(
          email: email,
          password: password,
        );
        final remoteUser = response.user;
        if (remoteUser == null) {
          throw StateError('Supabase returned no user for this sign-in.');
        }
        credentialsAccepted = true;
        final profile = await SupabaseSyncService().getUserProfile(
          remoteUser.id,
        );
        final localUser = await db.getUser(email);
        final profileName = profile?['name'] as String?;
        final localName = localUser?['full_name'] as String?;
        final metadataName = remoteUser.userMetadata?['full_name'] as String?;
        final name =
            localName != null &&
                localName.trim().isNotEmpty &&
                localName != 'User'
            ? localName
            : profileName != null &&
                  profileName.trim().isNotEmpty &&
                  profileName != 'User'
            ? profileName
            : metadataName != null &&
                  metadataName.trim().isNotEmpty &&
                  metadataName != 'User'
            ? metadataName
            : 'User';
        final tier = profile?['tier'] as String? ?? 'Free';
        final profileRole = profile?['role'] as String?;
        final metadataRole = remoteUser.userMetadata?['role'] as String?;
        final localRole = localUser?['role'] as String?;
        final role = profileRole == 'guardian' || profileRole == 'patient'
            ? profileRole!
            : metadataRole == 'guardian' || metadataRole == 'patient'
            ? metadataRole!
            : localRole == 'guardian' || localRole == 'patient'
            ? localRole!
            : 'patient';
        final storedAuthName = remoteUser.userMetadata?['full_name'] as String?;
        if (name != 'User' && storedAuthName != name) {
          try {
            await SupabaseService.client.auth.updateUser(
              UserAttributes(data: {'full_name': name}),
            );
          } catch (_) {
            // Name remains available in the public profile if Auth metadata
            // cannot be updated at this moment.
          }
        }
        if (localUser == null) {
          await db.createUser({
            'id': remoteUser.id,
            'email': email,
            'password': password,
            'full_name': name,
            'tier': tier,
            'role': role,
            'created_at': DateTime.now().millisecondsSinceEpoch,
          });
        } else if (localUser['full_name'] != name) {
          await db.updateUserName(email, name);
        }
        if (name != 'User') {
          await SupabaseSyncService().uploadUserProfile(
            userId: remoteUser.id,
            email: email,
            name: name,
            role: UserRoleX.fromString(role),
            tier: tier,
          );
        }
        auth.login(remoteUser.id, name, email, tier: tier, role: role);
        await appState.saveAuthSession(
          remoteUser.id,
          name,
          email,
          tier,
          role: role,
        );
        if (mounted) _navigateAfterAuth();
        return;
      } catch (error) {
        debugPrint('SupabaseAuth: sign-in flow failed: $error');
        if (!mounted) return;
        final emailNeedsConfirmation =
            error is AuthApiException && error.code == 'email_not_confirmed';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _authErrorMessage(
                error,
                fallback: credentialsAccepted
                    ? 'You’re signed in, but we could not load your account. Please try again.'
                    : 'We could not sign you in. Check your connection and try again.',
              ),
            ),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
            action: emailNeedsConfirmation
                ? SnackBarAction(
                    label: 'Resend',
                    textColor: Colors.white,
                    onPressed: () => _resendSignupConfirmation(email),
                  )
                : null,
          ),
        );
        return;
      }
    }

    if (_isLogin) {
      final user = await db.getUser(email);
      if (user == null) {
        final sync = SupabaseSyncService();
        final supabaseUser = await sync.findUserByEmail(email);
        if (supabaseUser != null) {
          final firePasswordHash =
              supabaseUser['passwordHash'] as String? ?? '';
          if (firePasswordHash.isNotEmpty &&
              db.verifyPassword(password, firePasswordHash)) {
            final restoredUser = {
              'id': supabaseUser['id'] as String,
              'email': email,
              'password': password,
              'full_name': supabaseUser['name'] as String? ?? 'User',
              'tier': supabaseUser['tier'] as String? ?? 'Free',
              'role': supabaseUser['role'] as String? ?? 'patient',
              'created_at': DateTime.now().millisecondsSinceEpoch,
            };
            await db.createUser(restoredUser);
            auth.login(
              restoredUser['id'] as String,
              restoredUser['full_name'] as String,
              email,
              tier: restoredUser['tier'] as String,
              role: restoredUser['role'] as String,
            );
            appState.saveAuthSession(
              restoredUser['id'] as String,
              restoredUser['full_name'] as String,
              email,
              restoredUser['tier'] as String,
              role: restoredUser['role'] as String,
            );
            final syncService = SupabaseSyncService();
            await syncService.uploadUserProfile(
              userId: auth.userId,
              email: auth.userEmail,
              name: auth.userName,
              role: auth.role,
              tier: auth.tier,
              passwordHash: db.hashPassword(password),
            );
            if (mounted) _navigateAfterAuth();
            return;
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Account found but password is incorrect. Use Forgot Password if needed.',
                ),
                backgroundColor: AppTheme.warning,
                behavior: SnackBarBehavior.floating,
                duration: Duration(seconds: 4),
              ),
            );
          }
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Invalid email or password'),
              backgroundColor: AppTheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      if (!db.verifyPassword(password, user['password'] as String)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Invalid email or password'),
              backgroundColor: AppTheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      if (isLegacyFormat(user['password'] as String)) {
        await db.updateUserPassword(email, password);
      }
      auth.login(
        user['id'],
        user['full_name'],
        email,
        tier: user['tier'] ?? 'Free',
        role: user['role'] ?? 'patient',
      );
      appState.saveAuthSession(
        user['id'],
        user['full_name'],
        email,
        user['tier'] ?? 'Free',
        role: user['role'] ?? 'patient',
      );
    } else {
      final existing = await db.getUser(email);
      if (existing != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Email already registered'),
              backgroundColor: AppTheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }

      String? supabaseUserId;
      try {
        if (!SupabaseService.isConfigured) {
          throw StateError('Supabase is not configured for this build.');
        }
        final response = await SupabaseService.client.auth.signUp(
          email: email,
          password: password,
          emailRedirectTo: SupabaseService.authCallbackUrl,
          data: {'full_name': _fullName, 'role': _selectedRole.name},
        );
        supabaseUserId = response.user?.id;
        if (response.session == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Account created. Check your email to confirm it before signing in.',
                ),
                backgroundColor: AppTheme.success,
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
          return;
        }
      } catch (error) {
        if (!mounted) return;
        final message = _authErrorMessage(
          error,
          fallback: 'Online account setup failed. Please try again.',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final newUser = {
        'id':
            supabaseUserId ?? DateTime.now().millisecondsSinceEpoch.toString(),
        'email': email,
        'password': password,
        'full_name': _fullName,
        'tier': 'Free',
        'role': _selectedRole.name,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      };
      await db.createUser(newUser);
      auth.login(
        newUser['id'] as String,
        newUser['full_name'] as String,
        email,
        tier: 'Free',
        role: _selectedRole.name,
      );
      appState.saveAuthSession(
        newUser['id'] as String,
        newUser['full_name'] as String,
        email,
        'Free',
        role: _selectedRole.name,
      );
    }

    final syncService = SupabaseSyncService();
    await syncService.uploadUserProfile(
      userId: auth.userId,
      email: auth.userEmail,
      name: auth.userName,
      role: auth.role,
      tier: auth.tier,
      passwordHash: db.hashPassword(password),
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isLogin ? 'Welcome back!' : 'Account created successfully!',
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppTheme.success,
        ),
      );
      _navigateAfterAuth();
    }
  }

  Future<void> _checkEmailAndContinue() async {
    if (!_formKey.currentState!.validate() || _checkingEmail) return;

    setState(() => _checkingEmail = true);

    // A missing local profile (or public.profiles row) does not prove that a
    // Supabase Auth user is new. Let Supabase verify the credentials on the
    // next step; account creation stays an explicit choice via the Sign Up
    // toggle, so clearing app storage cannot send an existing user into signup.
    if (SupabaseService.isConfigured) {
      if (!mounted) return;
      setState(() {
        _checkingEmail = false;
        _isLogin = true;
        _emailStep = false;
      });
      return;
    }

    final email = _emailController.text.trim().toLowerCase();
    final db = DatabaseHelper();
    var exists = await db.getUser(email) != null;

    if (!mounted) return;
    setState(() {
      _checkingEmail = false;
      if (exists) {
        _emailStep = false;
      } else {
        _isLogin = false;
        _emailStep = false;
      }
    });
  }

  Future<void> _signInWithGoogle() async {
    final auth = context.read<AuthProvider>();
    final appState = context.read<AppStateProvider>();
    try {
      if (!SupabaseService.isConfigured) {
        throw StateError('Supabase is not configured for this build.');
      }
      _googleInitialization ??= GoogleSignIn.instance.initialize(
        serverClientId: _googleServerClientId,
      );
      await _googleInitialization;

      if (!GoogleSignIn.instance.supportsAuthenticate()) {
        throw StateError(
          'Google Sign-In is unavailable in this platform build. '
          'Fully stop and rebuild the Android app.',
        );
      }

      final googleAccount = await GoogleSignIn.instance.authenticate();
      final googleAuth = googleAccount.authentication;
      final idToken = googleAuth.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw StateError('Google did not return an ID token.');
      }

      final authResponse = await SupabaseService.client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
      );
      final supabaseUser = authResponse.user;
      if (supabaseUser == null) {
        throw StateError('Google sign-in did not return a user.');
      }

      final email = (supabaseUser.email ?? googleAccount.email)
          .trim()
          .toLowerCase();
      final db = DatabaseHelper();
      final existing = await db.getUser(email);
      final supabase = SupabaseSyncService();
      final supabaseProfile = await supabase.findUserByEmail(email);
      final accountCreatedAt = DateTime.tryParse(supabaseUser.createdAt);
      final isFreshGoogleAccount =
          accountCreatedAt != null &&
          DateTime.now().toUtc().difference(accountCreatedAt.toUtc()).abs() <
              const Duration(minutes: 5);
      // The auth.users trigger inserts a default Patient profile before this
      // screen receives the Google response. Treat that freshly-created row
      // as a new account so the person can choose Guardian on first sign-in.
      final isNewGoogleUser =
          existing == null && (supabaseProfile == null || isFreshGoogleAccount);
      final userId =
          existing?['id'] as String? ??
          supabaseProfile?['id'] as String? ??
          supabaseUser.id;
      final name =
          existing?['full_name'] as String? ??
          supabaseProfile?['name'] as String? ??
          supabaseUser.userMetadata?['full_name'] as String? ??
          googleAccount.displayName ??
          'Google User';
      final tier =
          existing?['tier'] as String? ??
          supabaseProfile?['tier'] as String? ??
          'Free';
      final metadataRole = supabaseUser.userMetadata?['role'] as String?;
      final profileRole = supabaseProfile?['role'] as String?;
      final storedRole = profileRole == 'guardian'
          ? 'guardian'
          : (metadataRole == 'guardian' || metadataRole == 'patient')
          ? metadataRole
          : existing?['role'] as String? ?? profileRole;
      String? role = storedRole;
      final shouldChooseGoogleRole =
          isNewGoogleUser ||
          (profileRole == 'patient' &&
              metadataRole != 'guardian' &&
              metadataRole != 'patient');
      if (shouldChooseGoogleRole) {
        role = await _chooseGoogleRole(name);
        if (role == null) {
          await GoogleSignIn.instance.signOut();
          await SupabaseService.client.auth.signOut();
          return;
        }
      }
      role ??= 'patient';

      if (existing == null) {
        await db.createUser({
          'id': userId,
          'email': email,
          'password': 'google:$userId',
          'full_name': name,
          'tier': tier,
          'role': role,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      // Google users need a profile document just like email users. Store a
      // one-way local marker only; never write the Google credential itself.
      if (isNewGoogleUser || supabaseProfile == null) {
        await supabase.uploadUserProfile(
          userId: userId,
          email: email,
          name: name,
          role: UserRole.values.firstWhere(
            (value) => value.name == role,
            orElse: () => UserRole.patient,
          ),
          tier: tier,
          passwordHash: db.hashPassword('google:$userId'),
          authProvider: 'google',
        );
      }

      if (shouldChooseGoogleRole) {
        try {
          await SupabaseService.client.auth.updateUser(
            UserAttributes(data: {'role': role}),
          );
        } catch (error) {
          // The public profile below is authoritative for app access. This
          // metadata marker only prevents showing the role chooser next time.
          debugPrint('Google account role metadata was not saved: $error');
        }
        await supabase.saveGoogleAccountRole(
          userId: userId,
          email: email,
          name: name,
          role: UserRoleX.fromString(role),
        );
      }

      auth.login(userId, name, email, tier: tier, role: role);
      appState.saveAuthSession(userId, name, email, tier, role: role);

      if (mounted) {
        HapticFeedback.mediumImpact();
        _navigateAfterAuth();
      }
    } catch (error) {
      final cancelled = error.toString().toLowerCase().contains('cancel');
      if (!mounted || cancelled) return;
      final message = error is UnimplementedError
          ? 'Google Sign-In is not loaded in this app build. Fully stop the app, uninstall the old APK, then run a fresh build.'
          : 'Google sign-in could not be completed. Please try again.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: AppTheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _navigateAfterAuth() {
    final pendingPairingId =
        widget.pairingId ?? context.read<AppStateProvider>().pendingPairingId;
    if (pendingPairingId != null && pendingPairingId.isNotEmpty) {
      context.go(
        '/guardian?pairingId=${Uri.encodeQueryComponent(pendingPairingId)}',
      );
    } else {
      context.go('/');
    }
  }

  Future<String?> _chooseGoogleRole(String name) async {
    final role = await showDialog<UserRole>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final accessible = dialogContext
            .read<AppStateProvider>()
            .accessibilityMode
            .usesLargeText;
        final dark = Theme.of(dialogContext).brightness == Brightness.dark;
        final textColor = dark ? AppTheme.darkTextPrimary : AppTheme.inkText;
        final mutedColor = dark
            ? AppTheme.darkTextSecondary
            : AppTheme.mutedText;
        final moss = dark ? AppTheme.darkAccentGreen : AppTheme.ink;
        final surface = dark ? AppTheme.darkCardSurface : AppTheme.card;
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          backgroundColor: surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 470),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: moss.withValues(alpha: 0.14),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.person_add_alt_1_rounded,
                        color: moss,
                        size: 28,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Choose your role',
                    textAlign: TextAlign.center,
                    style: AppTheme.textStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Welcome, $name',
                    textAlign: TextAlign.center,
                    style: AppTheme.textStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'How would you like to use MediSense?',
                    textAlign: TextAlign.center,
                    style: AppTheme.textStyle(
                      fontSize: 16,
                      height: 1.35,
                      color: mutedColor,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _GoogleRoleCard(
                    icon: Icons.medication_rounded,
                    title: 'Patient',
                    description: 'Manage my medicine schedule and reminders.',
                    accent: moss,
                    textColor: textColor,
                    mutedColor: mutedColor,
                    dark: dark,
                    accessible: accessible,
                    onTap: () => Navigator.pop(dialogContext, UserRole.patient),
                  ),
                  const SizedBox(height: 12),
                  _GoogleRoleCard(
                    icon: Icons.family_restroom_rounded,
                    title: 'Guardian',
                    description: 'Help a family member manage their medicines.',
                    accent: moss,
                    textColor: AppTheme.primaryForeground,
                    mutedColor: AppTheme.primaryForeground.withValues(
                      alpha: 0.84,
                    ),
                    dark: dark,
                    accessible: accessible,
                    filled: true,
                    onTap: () =>
                        Navigator.pop(dialogContext, UserRole.guardian),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Select the role that best describes you.',
                    textAlign: TextAlign.center,
                    style: AppTheme.textStyle(
                      fontSize: accessible ? 17 : 13,
                      height: 1.35,
                      color: mutedColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    return role?.name;
  }

  void _showForgotPassword() {
    var email = '';
    showDialog(
      context: context,
      barrierColor: const Color.fromRGBO(44, 44, 36, 0.45),
      builder: (ctx) {
        final dark = Theme.of(ctx).brightness == Brightness.dark;
        final primaryText = dark ? AppTheme.darkTextPrimary : AppTheme.inkText;
        final secondaryText = dark
            ? AppTheme.darkTextSecondary
            : AppTheme.mutedText;
        final action = dark ? AppTheme.darkAccentGreen : AppTheme.ink;
        final fill = dark ? AppTheme.darkCardSurface : AppTheme.muted;
        final border = dark ? AppTheme.darkBorder : AppTheme.timber;

        return _ResetDialogShell(
          title: 'Reset Password',
          subtitle: 'Enter your email to receive a password reset link.',
          icon: Icons.lock_reset_rounded,
          primaryText: primaryText,
          secondaryText: secondaryText,
          actionColor: action,
          borderColor: border,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                onChanged: (value) => email = value,
                autofocus: true,
                style: AppTheme.textStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: primaryText,
                ),
                decoration: _resetInputDecoration(
                  label: 'Email address',
                  hint: 'name@example.com',
                  icon: Icons.email_outlined,
                  fill: fill,
                  border: border,
                  action: action,
                  secondaryText: secondaryText,
                ),
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _sendPasswordReset(ctx, email),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: () => _sendPasswordReset(ctx, email),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: action,
                    foregroundColor: AppTheme.primaryForeground,
                    elevation: 0,
                    alignment: Alignment.center,
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'Send Link',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: 48,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: TextButton.styleFrom(foregroundColor: primaryText),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _sendPasswordReset(
    BuildContext dialogContext,
    String rawEmail,
  ) async {
    final email = rawEmail.trim().toLowerCase();
    if (email.isEmpty || !email.contains('@')) {
      ScaffoldMessenger.of(dialogContext).showSnackBar(
        const SnackBar(content: Text('Please enter a valid email address')),
      );
      return;
    }

    final connectivity = await Connectivity().checkConnectivity();
    final isOffline =
        connectivity.isEmpty ||
        (connectivity.length == 1 &&
            connectivity.first == ConnectivityResult.none);
    if (isOffline) {
      if (dialogContext.mounted) {
        ScaffoldMessenger.of(dialogContext).showSnackBar(
          const SnackBar(
            content: Text(
              'No internet connection. Please try again when online.',
            ),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
      return;
    }

    try {
      if (!SupabaseService.isConfigured) {
        throw StateError('Supabase is not configured for this build.');
      }
      await SupabaseService.client.auth.resetPasswordForEmail(
        email,
        redirectTo: SupabaseService.passwordRecoveryUrl,
      );
      if (!dialogContext.mounted) return;
      Navigator.pop(dialogContext);
      if (mounted) _showResetEmailSentDialog(email);
    } catch (error) {
      if (!dialogContext.mounted) return;
      final message = error.toString().toLowerCase().contains('invalid')
          ? 'Please enter a valid email address.'
          : 'We could not send the reset email. Please try again.';
      ScaffoldMessenger.of(dialogContext).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: AppTheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  String _authErrorMessage(Object error, {required String fallback}) {
    final message = error.toString().toLowerCase();
    if (error is AuthApiException && error.code == 'email_not_confirmed') {
      return 'Please confirm your account using the email we sent, then sign in again.';
    }
    if (error is AuthApiException && error.code == 'invalid_credentials') {
      return 'The email or password is incorrect. If you recently changed devices, use Forgot Password to set a new password.';
    }
    if (error is AuthApiException) {
      return fallback;
    }
    if (error is AuthRetryableFetchException) {
      return 'We could not connect. Check your internet connection and try again.';
    }
    if (message.contains('already')) {
      return 'This email already has an online account. Try signing in.';
    }
    if (message.contains('invalid login credentials') ||
        message.contains('invalid_credentials')) {
      return 'The email or password is incorrect.';
    }
    if (message.contains('invalid email')) {
      return 'Please enter a valid email address.';
    }
    if (message.contains('weak password')) {
      return 'Choose a stronger password and try again.';
    }
    if (message.contains('network')) {
      return 'Unable to connect. Please try again.';
    }
    return fallback;
  }

  Future<void> _resendSignupConfirmation(String email) async {
    try {
      await SupabaseService.client.auth.resend(
        email: email,
        type: OtpType.signup,
        emailRedirectTo: SupabaseService.authCallbackUrl,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('A new confirmation email was sent.'),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Could not resend the confirmation email. Please try again.',
          ),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  InputDecoration _resetInputDecoration({
    required String label,
    required String hint,
    required IconData icon,
    required Color fill,
    required Color border,
    required Color action,
    required Color secondaryText,
  }) {
    OutlineInputBorder outline(Color color, [double width = 1.5]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: color, width: width),
        );
    return InputDecoration(
      labelText: label,
      hintText: hint,
      hintStyle: TextStyle(color: secondaryText, fontSize: 16),
      labelStyle: TextStyle(color: secondaryText, fontSize: 16),
      floatingLabelStyle: TextStyle(color: action, fontWeight: FontWeight.w700),
      prefixIcon: Icon(icon, color: secondaryText),
      filled: true,
      fillColor: fill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      enabledBorder: outline(border),
      focusedBorder: outline(action, 2),
    );
  }

  void _showResetEmailSentDialog(String email) {
    showDialog(
      context: context,
      barrierColor: const Color.fromRGBO(44, 44, 36, 0.45),
      builder: (ctx) {
        final dark = Theme.of(ctx).brightness == Brightness.dark;
        final primaryText = dark ? AppTheme.darkTextPrimary : AppTheme.inkText;
        final secondaryText = dark
            ? AppTheme.darkTextSecondary
            : AppTheme.mutedText;
        final action = dark ? AppTheme.darkAccentGreen : AppTheme.ink;
        return _ResetDialogShell(
          title: 'Reset link sent',
          subtitle: 'Check your inbox and spam folder to continue.',
          icon: Icons.mark_email_unread_rounded,
          primaryText: primaryText,
          secondaryText: secondaryText,
          actionColor: action,
          borderColor: dark ? AppTheme.darkBorder : AppTheme.timber,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'We sent a password reset link to $email. Open it on this device to choose a new password in MediSense.',
                style: AppTheme.textStyle(
                  fontSize: 16,
                  height: 1.45,
                  color: primaryText,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: action,
                    foregroundColor: AppTheme.primaryForeground,
                    elevation: 0,
                    alignment: Alignment.center,
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'Done',
                        maxLines: 1,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final accessible = context
        .watch<AppStateProvider>()
        .accessibilityMode
        .usesLargeText;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 0,
        title: const SizedBox.shrink(),
        leading: IconButton(
          tooltip: 'Close',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: Icon(Icons.close_rounded, color: _primaryText),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/');
            }
          },
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
            final keyboardOpen = keyboardInset > 0;
            return SingleChildScrollView(
              // Keep login and registration keyboard-safe. Flutter will bring
              // the focused field into view while this scroll view supplies
              // the remaining content above the IME.
              physics: const ClampingScrollPhysics(),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              primary: false,
              padding: EdgeInsets.fromLTRB(
                32,
                keyboardOpen ? 4 : 12,
                32,
                keyboardInset + (keyboardOpen ? 20 : 40),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight > 52
                      ? constraints.maxHeight - 52
                      : 0,
                ),
                child: Center(
                  child: SizedBox(
                    width: double.infinity,
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(height: keyboardOpen ? 4 : 10),
                          Center(
                            child: Container(
                              width: keyboardOpen ? 58 : 72,
                              height: keyboardOpen ? 58 : 72,
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color:
                                    Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? AppTheme.darkCardSurface
                                    : AppTheme.card,
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(
                                  color:
                                      Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? AppTheme.darkBorder
                                      : AppTheme.timber,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color.fromRGBO(44, 44, 36, 0.12),
                                    blurRadius: 16,
                                    offset: Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(19),
                                child: Image.asset(
                                  'assets/app_icon.png',
                                  width: double.infinity,
                                  height: double.infinity,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) =>
                                      Icon(
                                        Icons.medication_rounded,
                                        size: 40,
                                        color: _primaryAction,
                                      ),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(height: keyboardOpen ? 8 : 12),
                          Center(
                            child: Text(
                              'MediSense',
                              style: AppTheme.textStyle(
                                fontSize: keyboardOpen ? 20 : 22,
                                fontWeight: FontWeight.w800,
                                color: _primaryText,
                              ),
                            ),
                          ),
                          SizedBox(height: keyboardOpen ? 18 : 36),
                          Text(
                            _isLogin ? 'Welcome Back' : 'Create Account',
                            style: AppTheme.textStyle(
                              fontSize: accessible
                                  ? (keyboardOpen ? 30 : 34)
                                  : (keyboardOpen ? 26 : 28),
                              fontWeight: FontWeight.w800,
                              color: _primaryText,
                              letterSpacing: -1,
                            ),
                          ),
                          SizedBox(height: keyboardOpen ? 4 : 8),
                          Text(
                            _isLogin
                                ? 'Sign in to access your medicine schedule.'
                                : 'Create an account to save your medicines and reminders.',
                            style: AppTheme.textStyle(
                              fontSize: accessible
                                  ? (keyboardOpen ? 18 : 20)
                                  : (keyboardOpen ? 15 : 16),
                              color: _secondaryText,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          SizedBox(height: keyboardOpen ? 18 : 28),

                          if (!_isLogin) ...[
                            _buildLabel('Choose your role'),
                            const SizedBox(height: 8),
                            if (accessible)
                              Column(
                                children: [
                                  _RoleCard(
                                    icon: Icons.person_rounded,
                                    label: 'Patient',
                                    filipinoLabel: 'Pasyente',
                                    description:
                                        'Manage my medicines and reminders',
                                    isSelected:
                                        _selectedRole == UserRole.patient,
                                    accessible: true,
                                    onTap: () => setState(
                                      () => _selectedRole = UserRole.patient,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  _RoleCard(
                                    icon: Icons.family_restroom_rounded,
                                    label: 'Guardian',
                                    filipinoLabel: 'Tagapag-alaga',
                                    description:
                                        'Help manage someone’s medicines',
                                    isSelected:
                                        _selectedRole == UserRole.guardian,
                                    accessible: true,
                                    onTap: () => setState(
                                      () => _selectedRole = UserRole.guardian,
                                    ),
                                  ),
                                ],
                              )
                            else
                              Row(
                                children: [
                                  Expanded(
                                    child: _RoleCard(
                                      icon: Icons.person_rounded,
                                      label: 'Patient',
                                      filipinoLabel: 'Pasyente',
                                      description:
                                          'Manage my medicines and reminders',
                                      isSelected:
                                          _selectedRole == UserRole.patient,
                                      accessible: false,
                                      onTap: () => setState(
                                        () => _selectedRole = UserRole.patient,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: _RoleCard(
                                      icon: Icons.family_restroom_rounded,
                                      label: 'Guardian',
                                      filipinoLabel: 'Tagapag-alaga',
                                      description:
                                          'Help manage someone’s medicines',
                                      isSelected:
                                          _selectedRole == UserRole.guardian,
                                      accessible: false,
                                      onTap: () => setState(
                                        () => _selectedRole = UserRole.guardian,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            const SizedBox(height: 24),
                            _buildLabel('First Name'),
                            TextFormField(
                              controller: _firstNameController,
                              style: _inputTextStyle,
                              textCapitalization: TextCapitalization.words,
                              textInputAction: TextInputAction.next,
                              autofillHints: const [AutofillHints.givenName],
                              validator: (value) =>
                                  value == null || value.trim().isEmpty
                                  ? 'Required'
                                  : null,
                              decoration: _inputDecoration(
                                Icons.person_outline_rounded,
                                'First name',
                              ),
                            ),
                            const SizedBox(height: 18),
                            _buildLabel('Last Name'),
                            TextFormField(
                              controller: _lastNameController,
                              style: _inputTextStyle,
                              textCapitalization: TextCapitalization.words,
                              textInputAction: TextInputAction.next,
                              autofillHints: const [AutofillHints.familyName],
                              validator: (value) =>
                                  value == null || value.trim().isEmpty
                                  ? 'Required'
                                  : null,
                              decoration: _inputDecoration(
                                Icons.badge_outlined,
                                'Last name',
                              ),
                            ),
                            const SizedBox(height: 24),
                          ],

                          _buildLabel('Email Address'),
                          SizedBox(
                            height: accessible ? 64 : 56,
                            child: TextFormField(
                              controller: _emailController,
                              style: _inputTextStyle,
                              keyboardType: TextInputType.emailAddress,
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return 'Please enter an email';
                                }
                                final emailRegex = RegExp(
                                  r"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$",
                                );
                                if (!emailRegex.hasMatch(value)) {
                                  return 'Please enter a valid email';
                                }
                                return null;
                              },
                              decoration: _inputDecoration(
                                Icons.email_outlined,
                                'name@example.com',
                              ),
                            ),
                          ),
                          if (!_isLogin || !_emailStep) ...[
                            const SizedBox(height: 24),
                            _buildLabel('Password'),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: accessible ? 64 : 56,
                              ),
                              child: TextFormField(
                                controller: _passwordController,
                                focusNode: _passwordFocusNode,
                                style: _inputTextStyle,
                                obscureText: !_showPassword,
                                validator: _validatePassword,
                                onChanged: _isLogin
                                    ? null
                                    : (_) => setState(() {}),
                                decoration: _inputDecoration(
                                  Icons.lock_outline_rounded,
                                  'Enter your password',
                                  suffixIcon: IconButton(
                                    tooltip: _showPassword
                                        ? 'Hide password'
                                        : 'Show password',
                                    icon: Icon(
                                      _showPassword
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined,
                                    ),
                                    onPressed: () => setState(
                                      () => _showPassword = !_showPassword,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (!_isLogin && _passwordFocused) ...[
                              const SizedBox(height: 12),
                              _buildPasswordRequirements(),
                            ],
                          ],

                          if (!_isLogin) ...[
                            const SizedBox(height: 24),
                            _buildLabel('Confirm Password'),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: accessible ? 64 : 56,
                              ),
                              child: TextFormField(
                                controller: _confirmPasswordController,
                                style: _inputTextStyle,
                                obscureText: true,
                                validator: (value) {
                                  if (value != _passwordController.text) {
                                    return 'Passwords do not match';
                                  }
                                  return null;
                                },
                                decoration: _inputDecoration(
                                  Icons.lock_reset_rounded,
                                  'Confirm your password',
                                ),
                              ),
                            ),
                          ],

                          SizedBox(height: keyboardOpen ? 20 : 40),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: () {
                                HapticFeedback.mediumImpact();
                                if (_isLogin && _emailStep) {
                                  _checkEmailAndContinue();
                                } else {
                                  _submit();
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _primaryAction,
                                foregroundColor: _buttonText,
                                minimumSize: const Size.fromHeight(56),
                                padding: EdgeInsets.zero,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                elevation: 0,
                              ),
                              child: _checkingEmail
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                        color: Colors.white,
                                      ),
                                    )
                                  : Text(
                                      _isLogin
                                          ? (_emailStep
                                                ? 'CONTINUE'
                                                : 'SIGN IN')
                                          : 'CREATE ACCOUNT',
                                      style: AppTheme.textStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 18,
                                        letterSpacing: 1,
                                      ),
                                    ),
                            ),
                          ),
                          if (_isLogin) ...[
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              height: accessible ? 60 : 52,
                              child: OutlinedButton.icon(
                                onPressed: _signInWithGoogle,
                                icon: const Icon(Icons.account_circle_outlined),
                                label: Text(
                                  'Continue with Google',
                                  style: TextStyle(
                                    fontSize: accessible ? 18 : 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: _primaryText,
                                  alignment: Alignment.center,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  side: BorderSide(
                                    color: _primaryText.withValues(alpha: 0.35),
                                    width: 1.5,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                              ),
                            ),
                            if (!_emailStep) ...[
                              const SizedBox(height: 12),
                              Center(
                                child: TextButton(
                                  onPressed: _showForgotPassword,
                                  child: Text(
                                    'Forgot Password?',
                                    style: AppTheme.textStyle(
                                      color: _secondaryText,
                                      fontSize: accessible ? 18 : 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                          const SizedBox(height: 24),
                          Center(
                            child: TextButton(
                              onPressed: () => setState(() {
                                _isLogin = !_isLogin;
                                _emailStep = _isLogin;
                                _formKey.currentState?.reset();
                                _selectedRole = UserRole.patient;
                              }),
                              child: RichText(
                                text: TextSpan(
                                  text: _isLogin
                                      ? "Don't have an account? "
                                      : "Already have an account? ",
                                  style: AppTheme.textStyle(
                                    color: _secondaryText,
                                    fontSize: accessible ? 18 : 15,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  children: [
                                    TextSpan(
                                      text: _isLogin ? 'Sign Up' : 'Sign In',
                                      style: TextStyle(
                                        color: _primaryAction,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 40),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildLabel(String label) {
    final accessible = context
        .read<AppStateProvider>()
        .accessibilityMode
        .usesLargeText;
    final isSectionLabel = label == 'Choose your role';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        label,
        style: AppTheme.textStyle(
          fontSize: accessible
              ? (isSectionLabel ? 20 : 18)
              : (isSectionLabel ? 18 : 16),
          fontWeight: FontWeight.w700,
          color: _primaryText,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildPasswordRequirements() {
    final accessible = context
        .read<AppStateProvider>()
        .accessibilityMode
        .usesLargeText;
    final password = _passwordController.text;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final rules = <MapEntry<String, bool>>[
      MapEntry('8+ characters', _hasMinimumPasswordLength(password)),
      MapEntry('Uppercase letter', _hasUppercase(password)),
      MapEntry('Lowercase letter', _hasLowercase(password)),
      MapEntry('Number', _hasNumber(password)),
      MapEntry('Special character', _hasSpecialCharacter(password)),
    ];

    Widget ruleChip(MapEntry<String, bool> rule) {
      final met = rule.value;
      return Semantics(
        label: '${rule.key}: ${met ? 'complete' : 'required'}',
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: met
                ? _primaryAction.withValues(alpha: dark ? 0.24 : 0.10)
                : (dark ? AppTheme.darkSurface : AppTheme.paper),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: met
                  ? _primaryAction
                  : (dark ? AppTheme.darkBorder : AppTheme.timber),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                met
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 16,
                color: met ? _primaryAction : _secondaryText,
              ),
              const SizedBox(width: 6),
              Text(
                rule.key,
                style: AppTheme.textStyle(
                  fontSize: accessible ? 16 : 13,
                  fontWeight: met ? FontWeight.w700 : FontWeight.w600,
                  color: met ? _primaryAction : _secondaryText,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Semantics(
      key: _passwordRequirementsKey,
      container: true,
      label: 'Password requirements',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: dark ? AppTheme.darkCardSurface : AppTheme.muted,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: dark ? AppTheme.darkBorder : AppTheme.timber,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Password must include',
              style: AppTheme.textStyle(
                fontSize: accessible ? 17 : 14,
                fontWeight: FontWeight.w700,
                color: _primaryText,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: rules.map(ruleChip).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Color get _primaryText => Theme.of(context).brightness == Brightness.dark
      ? AppTheme.darkTextPrimary
      : AppTheme.inkText;

  Color get _secondaryText => Theme.of(context).brightness == Brightness.dark
      ? AppTheme.darkTextSecondary
      : AppTheme.mutedText;

  Color get _primaryAction => Theme.of(context).brightness == Brightness.dark
      ? AppTheme.darkAccentGreen
      : AppTheme.ink;

  Color get _buttonText => Theme.of(context).brightness == Brightness.dark
      ? AppTheme.darkPrimaryForeground
      : AppTheme.primaryForeground;

  Color get _inputHint => Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF78786C)
      : AppTheme.mutedText;

  TextStyle get _inputTextStyle => AppTheme.textStyle(
    fontSize: context.read<AppStateProvider>().accessibilityMode.usesLargeText
        ? 19
        : 16,
    fontWeight: FontWeight.w700,
    color: _primaryText,
  );

  InputDecoration _inputDecoration(
    IconData? icon,
    String hint, {
    Widget? suffixIcon,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = dark ? AppTheme.darkBorder : AppTheme.timber;
    return InputDecoration(
      prefixIcon: icon == null
          ? null
          : Icon(icon, color: _secondaryText, size: 22),
      suffixIcon: suffixIcon,
      hintText: hint,
      hintStyle: TextStyle(
        color: _inputHint,
        fontSize:
            context.read<AppStateProvider>().accessibilityMode.usesLargeText
            ? 18
            : 16,
        fontStyle: FontStyle.normal,
        fontWeight: FontWeight.w500,
      ),
      filled: true,
      fillColor: dark ? AppTheme.darkCardSurface : AppTheme.muted,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: borderColor, width: 1.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: borderColor, width: 1.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: _primaryAction, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: AppTheme.error, width: 1),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
    );
  }
}

class _ResetDialogShell extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color primaryText;
  final Color secondaryText;
  final Color actionColor;
  final Color borderColor;
  final Widget child;

  const _ResetDialogShell({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.primaryText,
    required this.secondaryText,
    required this.actionColor,
    required this.borderColor,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      backgroundColor: dark ? AppTheme.darkCardSurface : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: BorderSide(color: borderColor),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: actionColor.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: actionColor, size: 30),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppTheme.textStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: primaryText,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: AppTheme.textStyle(
                fontSize: 15,
                height: 1.4,
                color: secondaryText,
              ),
            ),
            const SizedBox(height: 22),
            child,
          ],
        ),
      ),
    );
  }
}

class _GoogleRoleCard extends StatelessWidget {
  const _GoogleRoleCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.accent,
    required this.textColor,
    required this.mutedColor,
    required this.dark,
    required this.accessible,
    required this.onTap,
    this.filled = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final Color accent;
  final Color textColor;
  final Color mutedColor;
  final bool dark;
  final bool accessible;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final border = filled
        ? accent
        : accent.withValues(alpha: dark ? 0.72 : 0.48);
    final background = filled
        ? accent
        : dark
        ? AppTheme.darkSurface
        : AppTheme.paper;
    final iconBackground = filled
        ? AppTheme.primaryForeground.withValues(alpha: 0.18)
        : accent.withValues(alpha: 0.13);

    return Semantics(
      button: true,
      label: '$title. $description',
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: border, width: filled ? 1.5 : 1.8),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: EdgeInsets.all(accessible ? 20 : 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: iconBackground,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: textColor, size: 26),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: AppTheme.textStyle(
                          fontSize: accessible ? 24 : 20,
                          fontWeight: FontWeight.w800,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        description,
                        softWrap: true,
                        style: AppTheme.textStyle(
                          fontSize: accessible ? 18 : 14,
                          height: 1.28,
                          color: mutedColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.arrow_forward_rounded, color: textColor, size: 22),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String filipinoLabel;
  final String description;
  final bool isSelected;
  final bool accessible;
  final VoidCallback onTap;

  const _RoleCard({
    required this.icon,
    required this.label,
    required this.filipinoLabel,
    required this.description,
    required this.isSelected,
    required this.accessible,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cardMuted = AppTheme.secondaryTextColor(context);
    final activeFill = dark ? const Color(0xFF3B4E34) : AppTheme.ink;
    final activeBorder = dark ? const Color(0xFFA3B899) : AppTheme.ink;
    final inactiveTitle = AppTheme.primaryTextColor(context);
    final selectedText = AppTheme.primaryForeground;
    return Semantics(
      button: true,
      selected: isSelected,
      label: '$label, $filipinoLabel. $description',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                constraints: BoxConstraints(minHeight: accessible ? 0 : 178),
                padding: EdgeInsets.fromLTRB(
                  16,
                  accessible ? 22 : 18,
                  16,
                  accessible ? 20 : 16,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? activeFill
                      : dark
                      ? AppTheme.darkCardSurface
                      : AppTheme.card,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelected
                        ? activeBorder
                        : dark
                        ? AppTheme.darkBorder
                        : AppTheme.timber,
                    width: isSelected ? 2 : 1.5,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: accessible ? 64 : 54,
                      height: accessible ? 64 : 54,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? selectedText.withValues(alpha: 0.13)
                            : activeBorder.withValues(alpha: 0.10),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        icon,
                        color: isSelected ? selectedText : activeBorder,
                        size: accessible ? 34 : 30,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      label,
                      style: AppTheme.textStyle(
                        fontSize: accessible ? 22 : 17,
                        fontWeight: FontWeight.w800,
                        color: isSelected ? selectedText : inactiveTitle,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      filipinoLabel,
                      style: AppTheme.textStyle(
                        fontSize: accessible ? 17 : 12,
                        fontWeight: FontWeight.w600,
                        color: isSelected
                            ? selectedText.withValues(alpha: 0.88)
                            : cardMuted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      description,
                      textAlign: TextAlign.center,
                      style: AppTheme.textStyle(
                        fontSize: accessible ? 16 : 11,
                        fontWeight: FontWeight.w600,
                        color: isSelected
                            ? selectedText.withValues(alpha: 0.88)
                            : cardMuted,
                        height: 1.35,
                      ),
                      maxLines: accessible ? null : 3,
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: const BoxDecoration(
                      color: AppTheme.primaryForeground,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.check_rounded,
                      color: activeFill,
                      size: 20,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
