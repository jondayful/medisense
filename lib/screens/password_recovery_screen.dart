import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/database_helper.dart';
import '../models/accessibility_mode.dart';
import '../providers/app_state_provider.dart';
import '../providers/auth_provider.dart';
import '../services/supabase_service.dart';
import '../services/password_rules.dart';
import '../theme/app_theme.dart';

class PasswordRecoveryScreen extends StatefulWidget {
  const PasswordRecoveryScreen({super.key, required this.status});

  final String status;

  @override
  State<PasswordRecoveryScreen> createState() => _PasswordRecoveryScreenState();
}

class _PasswordRecoveryScreenState extends State<PasswordRecoveryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordRequirementsKey = GlobalKey();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _passwordFocusNode = FocusNode();
  bool _showPassword = false;
  bool _showConfirm = false;
  bool _passwordFocused = false;
  bool _saving = false;
  bool _complete = false;
  String? _error;

  bool _hasSpecialCharacter(String value) => PasswordRules.hasSymbol(value);

  @override
  void initState() {
    super.initState();
    _passwordFocusNode.addListener(_handlePasswordFocusChange);
  }

  void _handlePasswordFocusChange() {
    if (!mounted || _passwordFocused == _passwordFocusNode.hasFocus) return;
    setState(() => _passwordFocused = _passwordFocusNode.hasFocus);
    if (!_passwordFocused) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        if (!mounted || !_passwordFocusNode.hasFocus) return;
        final requirementsContext = _passwordRequirementsKey.currentContext;
        if (requirementsContext == null || !requirementsContext.mounted) return;
        Scrollable.ensureVisible(
          requirementsContext,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          alignment: 0.25,
        );
      });
    });
  }

  @override
  void dispose() {
    _passwordFocusNode
      ..removeListener(_handlePasswordFocusChange)
      ..dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String? _validatePassword(String? value) {
    final password = value ?? '';
    if (password.isEmpty) return 'Enter a new password.';
    if (password.length < 8 ||
        !RegExp(r'[A-Z]').hasMatch(password) ||
        !RegExp(r'[a-z]').hasMatch(password) ||
        !RegExp(r'[0-9]').hasMatch(password) ||
        !_hasSpecialCharacter(password)) {
      return 'Meet all password requirements below.';
    }
    return null;
  }

  Future<void> _savePassword() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) {
      if (_validatePassword(_password.text) != null) {
        _passwordFocusNode.requestFocus();
      }
      return;
    }
    final session = SupabaseService.client.auth.currentSession;
    if (session == null) {
      setState(() => _error = 'This link has expired. Request a new one.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await SupabaseService.client.auth.updateUser(
        UserAttributes(password: _password.text),
      );
    } catch (error) {
      debugPrint('Password update failed: $error');
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not update your password. Please try again.';
      });
      return;
    }

    final email = session.user.email;
    if (email != null) {
      try {
        await DatabaseHelper().updateUserPassword(email, _password.text);
      } catch (error) {
        debugPrint('Local password update failed: $error');
      }
    }
    try {
      await SupabaseService.client.auth.signOut();
    } catch (error) {
      debugPrint('Sign out after password reset failed: $error');
    }
    if (!mounted) return;
    context.read<AuthProvider>().logout();
    await context.read<AppStateProvider>().clearAuthSession();
    if (!mounted) return;
    _password.clear();
    _confirm.clear();
    setState(() {
      _saving = false;
      _complete = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final checking = widget.status == 'checking';
    final ready = widget.status == 'ready';
    final isLarge = context
        .watch<AppStateProvider>()
        .accessibilityMode
        .usesLargeText;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final action = AppTheme.actionColor(context);
    final primary = AppTheme.primaryTextColor(context);
    final secondary = AppTheme.secondaryTextColor(context);
    final title = _complete
        ? 'Password updated'
        : checking
        ? 'Opening reset link'
        : ready
        ? 'Choose a new password'
        : 'Reset link unavailable';

    return Scaffold(
      backgroundColor: AppTheme.pageColor(context),
      appBar: AppBar(
        backgroundColor: AppTheme.pageColor(context),
        foregroundColor: primary,
        centerTitle: true,
        toolbarHeight: isLarge ? 80 : 64,
        leading: IconButton(
          tooltip: 'Back to sign in',
          onPressed: () => context.go('/auth'),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Text(
          'Reset password',
          style: AppTheme.textStyle(
            fontSize: isLarge ? 30 : 23,
            fontWeight: FontWeight.w800,
            color: primary,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(24, isLarge ? 32 : 24, 24, 40),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: isLarge ? 88 : 72,
                      height: isLarge ? 88 : 72,
                      decoration: BoxDecoration(
                        color: action.withValues(alpha: dark ? 0.20 : 0.10),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Icon(
                        _complete
                            ? Icons.check_circle_rounded
                            : ready
                            ? Icons.lock_reset_rounded
                            : checking
                            ? Icons.mark_email_read_outlined
                            : Icons.link_off_rounded,
                        size: isLarge ? 48 : 40,
                        color: action,
                      ),
                    ),
                  ),
                  SizedBox(height: isLarge ? 24 : 20),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: AppTheme.textStyle(
                      fontSize: isLarge ? 32 : 26,
                      fontWeight: FontWeight.w800,
                      color: primary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _complete
                        ? 'Your password is ready. Sign in with your new password.'
                        : checking
                        ? 'Please wait while we open your link.'
                        : ready
                        ? 'Enter a new password for your MediSense account.'
                        : 'This link may have expired or already been used. Request a new reset link from sign in.',
                    textAlign: TextAlign.center,
                    style: AppTheme.textStyle(
                      fontSize: isLarge ? 20 : 16,
                      height: 1.5,
                      color: secondary,
                    ),
                  ),
                  if (checking) ...[
                    const SizedBox(height: 32),
                    Center(child: CircularProgressIndicator(color: action)),
                  ],
                  if (ready && !_complete) ...[
                    SizedBox(height: isLarge ? 32 : 28),
                    Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _fieldLabel(context, 'New password', isLarge),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _password,
                            focusNode: _passwordFocusNode,
                            obscureText: !_showPassword,
                            autofillHints: const [AutofillHints.newPassword],
                            textInputAction: TextInputAction.next,
                            style: AppTheme.textStyle(
                              fontSize: isLarge ? 21 : 17,
                              color: primary,
                            ),
                            onChanged: (_) => setState(() {}),
                            validator: _validatePassword,
                            decoration: _fieldDecoration(
                              context,
                              label: 'New password',
                              visible: _showPassword,
                              isLarge: isLarge,
                              onToggle: () => setState(
                                () => _showPassword = !_showPassword,
                              ),
                            ),
                          ),
                          if (_passwordFocused) ...[
                            SizedBox(height: isLarge ? 16 : 12),
                            KeyedSubtree(
                              key: _passwordRequirementsKey,
                              child: _passwordRequirements(context, isLarge),
                            ),
                          ],
                          SizedBox(height: isLarge ? 24 : 20),
                          _fieldLabel(context, 'Confirm new password', isLarge),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _confirm,
                            obscureText: !_showConfirm,
                            autofillHints: const [AutofillHints.newPassword],
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => _savePassword(),
                            style: AppTheme.textStyle(
                              fontSize: isLarge ? 21 : 17,
                              color: primary,
                            ),
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return 'Confirm your new password.';
                              }
                              return value == _password.text
                                  ? null
                                  : 'Passwords do not match.';
                            },
                            decoration: _fieldDecoration(
                              context,
                              label: 'Confirm new password',
                              visible: _showConfirm,
                              isLarge: isLarge,
                              onToggle: () =>
                                  setState(() => _showConfirm = !_showConfirm),
                            ),
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 16),
                            Text(
                              _error!,
                              style: AppTheme.textStyle(
                                fontSize: isLarge ? 18 : 15,
                                color: dark
                                    ? AppTheme.darkError
                                    : AppTheme.error,
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                          FilledButton(
                            onPressed: _saving ? null : _savePassword,
                            style: FilledButton.styleFrom(
                              minimumSize: Size.fromHeight(isLarge ? 64 : 56),
                              backgroundColor: action,
                              foregroundColor: AppTheme.actionForegroundColor(
                                context,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 14,
                              ),
                            ),
                            child: Text(
                              _saving ? 'Updating password' : 'Update password',
                              textAlign: TextAlign.center,
                              style: AppTheme.textStyle(
                                fontSize: isLarge ? 20 : 17,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.actionForegroundColor(context),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_complete || (!checking && !ready)) ...[
                    const SizedBox(height: 32),
                    FilledButton(
                      onPressed: () => context.go('/auth'),
                      style: FilledButton.styleFrom(
                        minimumSize: Size.fromHeight(isLarge ? 64 : 56),
                        backgroundColor: action,
                        foregroundColor: AppTheme.actionForegroundColor(
                          context,
                        ),
                      ),
                      child: Text(
                        _complete ? 'Sign in' : 'Go to sign in',
                        style: AppTheme.textStyle(
                          fontSize: isLarge ? 20 : 17,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.actionForegroundColor(context),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _fieldDecoration(
    BuildContext context, {
    required String label,
    required bool visible,
    required bool isLarge,
    required VoidCallback onToggle,
  }) {
    final border = AppTheme.borderColor(context);
    final secondary = AppTheme.secondaryTextColor(context);
    final fill = Theme.of(context).brightness == Brightness.dark
        ? AppTheme.darkInputSurface
        : AppTheme.surfaceColor(context);
    return InputDecoration(
      hintText: 'Enter here',
      hintStyle: AppTheme.textStyle(
        fontSize: isLarge ? 20 : 16,
        color: secondary,
      ),
      filled: true,
      fillColor: fill,
      contentPadding: EdgeInsets.symmetric(
        horizontal: 16,
        vertical: isLarge ? 20 : 16,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color: AppTheme.actionColor(context),
          width: 1.5,
        ),
      ),
      errorMaxLines: 2,
      prefixIcon: Icon(Icons.lock_outline_rounded, color: secondary),
      suffixIcon: IconButton(
        tooltip: visible ? 'Hide $label' : 'Show $label',
        onPressed: onToggle,
        color: secondary,
        icon: Icon(
          visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        ),
      ),
    );
  }

  Widget _fieldLabel(BuildContext context, String label, bool isLarge) {
    return Text(
      label,
      style: AppTheme.textStyle(
        fontSize: isLarge ? 20 : 16,
        fontWeight: FontWeight.w700,
        color: AppTheme.primaryTextColor(context),
      ),
    );
  }

  Widget _passwordRequirements(BuildContext context, bool isLarge) {
    final value = _password.text;
    final rules = <(String, bool)>[
      ('8+ characters', value.length >= 8),
      ('Uppercase letter', RegExp(r'[A-Z]').hasMatch(value)),
      ('Lowercase letter', RegExp(r'[a-z]').hasMatch(value)),
      ('Number', RegExp(r'[0-9]').hasMatch(value)),
      ('Special character', _hasSpecialCharacter(value)),
    ];
    final action = AppTheme.actionColor(context);
    final secondary = AppTheme.secondaryTextColor(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(isLarge ? 18 : 16),
      decoration: BoxDecoration(
        color: dark ? AppTheme.darkCardSurface : AppTheme.muted,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Password must include',
            style: AppTheme.textStyle(
              fontSize: isLarge ? 19 : 15,
              fontWeight: FontWeight.w700,
              color: AppTheme.primaryTextColor(context),
            ),
          ),
          const SizedBox(height: 12),
          Column(
            children: rules.map((rule) {
              final (label, met) = rule;
              return Semantics(
                label: '$label: ${met ? 'complete' : 'required'}',
                excludeSemantics: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(
                        met
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: isLarge ? 22 : 20,
                        color: met ? action : secondary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          label,
                          softWrap: true,
                          style: AppTheme.textStyle(
                            fontSize: isLarge ? 17 : 14,
                            fontWeight: FontWeight.w600,
                            color: met ? action : secondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
