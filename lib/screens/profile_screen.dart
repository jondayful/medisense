import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/database_helper.dart';
import '../models/accessibility_mode.dart';
import '../providers/app_state_provider.dart';
import '../providers/auth_provider.dart';
import '../services/subscription_service.dart';
import '../services/supabase_service.dart';
import '../services/supabase_sync_service.dart';
import '../theme/app_theme.dart';

bool _usesLargeText(BuildContext context) =>
    context.select<AppStateProvider, bool>(
      (state) => state.accessibilityMode.usesLargeText,
    );

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final isLarge = context
        .watch<AppStateProvider>()
        .accessibilityMode
        .usesLargeText;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = dark ? AppTheme.darkAccentGreen : AppTheme.ink;
    final text = dark ? AppTheme.darkTextPrimary : AppTheme.inkText;
    final muted = dark ? AppTheme.darkTextSecondary : AppTheme.mutedText;
    final surface = dark ? AppTheme.darkCardSurface : Colors.white;
    final border = dark ? AppTheme.darkBorder : AppTheme.timber;
    final initials = auth.userName
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .take(2)
        .map((s) => s[0])
        .join()
        .toUpperCase();

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        toolbarHeight: isLarge ? 80 : null,
        title: Text(
          'Account',
          style: AppTheme.textStyle(
            fontSize: isLarge ? 30 : 22,
            fontWeight: FontWeight.w800,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          tooltip: 'Back',
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              // Payment deep links use go('/profile'), so Profile can be the
              // root route with no history to pop back to.
              context.go('/');
            }
          },
        ),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          isLarge ? 24 : 20,
          isLarge ? 24 : 18,
          isLarge ? 24 : 20,
          isLarge ? 48 : 36,
        ),
        children: [
          Center(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(
                  radius: isLarge ? 62 : 54,
                  backgroundColor: accent.withValues(alpha: .14),
                  child: Text(
                    initials.isEmpty ? 'M' : initials,
                    style: AppTheme.textStyle(
                      fontSize: isLarge ? 40 : 34,
                      fontWeight: FontWeight.w800,
                      color: accent,
                    ),
                  ),
                ),
                Positioned(
                  right: -4,
                  bottom: -4,
                  child: Semantics(
                    button: true,
                    label: 'Change profile photo',
                    child: Material(
                      color: accent,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Profile photo upload will be available soon.',
                            ),
                          ),
                        ),
                        child: const SizedBox(
                          width: 48,
                          height: 48,
                          child: Icon(
                            Icons.camera_alt_rounded,
                            size: 21,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: isLarge ? 20 : 16),
          Text(
            auth.userName,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: AppTheme.textStyle(
              fontSize: isLarge ? 32 : 27,
              fontWeight: FontWeight.w800,
              color: text,
            ),
          ),
          SizedBox(height: isLarge ? 12 : 8),
          Center(
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: isLarge ? 16 : 12,
                vertical: isLarge ? 8 : 6,
              ),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                '${auth.tier} Plan Member',
                style: AppTheme.textStyle(
                  fontSize: isLarge ? 16 : 13,
                  fontWeight: FontWeight.w800,
                  color: accent,
                ),
              ),
            ),
          ),
          SizedBox(height: isLarge ? 36 : 34),
          Text(
            'Account Settings',
            style: AppTheme.textStyle(
              fontSize: isLarge ? 19 : 14,
              fontWeight: FontWeight.w800,
              color: muted,
            ),
          ),
          const SizedBox(height: 10),
          DecoratedBox(
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: border),
            ),
            child: Column(
              children: [
                _Row(
                  icon: Icons.badge_outlined,
                  color: accent,
                  title: 'Display Name',
                  detail: auth.userName,
                  isLarge: isLarge,
                  onTap: () => _nameSheet(context, auth.userName),
                ),
                Divider(height: 1, indent: 76, color: border),
                _Row(
                  icon: Icons.email_outlined,
                  color: accent,
                  title: 'Change Email',
                  detail: auth.userEmail,
                  isLarge: isLarge,
                  onTap: () => _emailSheet(context, auth.userEmail),
                ),
                Divider(height: 1, indent: 76, color: border),
                _Row(
                  icon: Icons.lock_outline_rounded,
                  color: dark ? AppTheme.darkFoil : AppTheme.foil,
                  title: 'Change Password',
                  detail: 'Keep your account secure',
                  isLarge: isLarge,
                  onTap: () => _passwordSheet(context),
                ),
                Divider(height: 1, indent: 76, color: border),
                _Row(
                  icon: Icons.workspace_premium_outlined,
                  color: AppTheme.foil,
                  title: 'Subscription Plan',
                  detail: '${auth.tier} plan',
                  isLarge: isLarge,
                  onTap: () => _subscriptionSheet(context),
                ),
                Divider(height: 1, indent: 76, color: border),
                _Row(
                  icon: Icons.notifications_none_rounded,
                  color: accent,
                  title: 'Notification Settings',
                  detail: 'Reminders and alerts',
                  isLarge: isLarge,
                  onTap: () => context.go('/settings'),
                ),
              ],
            ),
          ),
          SizedBox(height: isLarge ? 32 : 38),
          OutlinedButton.icon(
            onPressed: () async {
              final authProvider = context.read<AuthProvider>();
              final appState = context.read<AppStateProvider>();
              if (SupabaseService.isConfigured &&
                  SupabaseService.client.auth.currentUser != null) {
                await SupabaseService.client.auth.signOut();
              }
              authProvider.logout();
              await appState.clearAuthSession();
              if (context.mounted) context.go('/');
            },
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Log out'),
            style: OutlinedButton.styleFrom(
              minimumSize: Size.fromHeight(isLarge ? 64 : 54),
              foregroundColor: AppTheme.error,
              backgroundColor: AppTheme.error.withValues(alpha: .08),
              side: BorderSide(color: AppTheme.error.withValues(alpha: .3)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              textStyle: AppTheme.textStyle(
                fontSize: isLarge ? 19 : 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _emailSheet(BuildContext context, String email) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _EmailSheet(email: email),
      );
  void _nameSheet(BuildContext context, String name) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _NameSheet(name: name),
      );
  void _passwordSheet(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _PasswordSheet(),
  );
  void _subscriptionSheet(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _SubscriptionSheet(),
  );
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.color,
    required this.title,
    required this.detail,
    required this.isLarge,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final String title, detail;
  final bool isLarge;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: isLarge ? 18 : 14,
        ),
        child: Row(
          children: [
            Container(
              width: isLarge ? 52 : 44,
              height: isLarge ? 52 : 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .14),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: isLarge ? 27 : 22),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTheme.textStyle(
                      fontSize: isLarge ? 22 : 16,
                      fontWeight: FontWeight.w800,
                      color: dark ? AppTheme.darkTextPrimary : AppTheme.inkText,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    maxLines: 2,
                    softWrap: true,
                    style: AppTheme.textStyle(
                      fontSize: isLarge ? 17 : 13,
                      height: 1.35,
                      color: dark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.mutedText,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: dark ? AppTheme.darkTextSecondary : AppTheme.mutedText,
              size: isLarge ? 28 : 24,
            ),
          ],
        ),
      ),
    );
  }
}

class _Sheet extends StatelessWidget {
  const _Sheet({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).brightness == Brightness.dark
          ? AppTheme.darkCardSurface
          : AppTheme.paper,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
    ),
    child: SafeArea(top: false, child: child),
  );
}

class _NameSheet extends StatefulWidget {
  const _NameSheet({required this.name});
  final String name;

  @override
  State<_NameSheet> createState() => _NameSheetState();
}

class _NameSheetState extends State<_NameSheet> {
  late final TextEditingController nameController;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(text: widget.name);
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final name = nameController.text.trim();
    if (name.isEmpty) return;
    setState(() => saving = true);
    final auth = context.read<AuthProvider>();
    final appState = context.read<AppStateProvider>();

    try {
      if (SupabaseService.isConfigured &&
          SupabaseService.client.auth.currentUser?.id == auth.userId) {
        await SupabaseService.client.auth.updateUser(
          UserAttributes(data: {'full_name': name}),
        );
        await SupabaseSyncService().uploadUserProfile(
          userId: auth.userId,
          email: auth.userEmail,
          name: name,
          role: auth.role,
          tier: auth.tier,
        );
      }
      await DatabaseHelper().updateUserName(auth.userEmail, name);
      auth.updateName(name);
      await appState.saveAuthSession(
        auth.userId,
        name,
        auth.userEmail,
        auth.tier,
        role: auth.role.name,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not update your display name. Please try again.',
          ),
        ),
      );
      return;
    }

    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Display name updated')));
  }

  @override
  Widget build(BuildContext context) {
    final isLarge = _usesLargeText(context);
    return _Sheet(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Display Name',
              style: AppTheme.textStyle(
                fontSize: isLarge ? 30 : 24,
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: isLarge ? 16 : 12),
            TextField(
              controller: nameController,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Your name',
                labelStyle: AppTheme.textStyle(fontSize: isLarge ? 17 : 14),
              ),
              onSubmitted: (_) => save(),
            ),
            SizedBox(height: isLarge ? 20 : 16),
            FilledButton(
              onPressed: saving ? null : save,
              style: _button(context),
              child: Text(saving ? 'Saving…' : 'Save Name'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmailSheet extends StatefulWidget {
  const _EmailSheet({required this.email});
  final String email;
  @override
  State<_EmailSheet> createState() => _EmailSheetState();
}

class _EmailSheetState extends State<_EmailSheet> {
  final next = TextEditingController();
  bool saving = false;
  @override
  void dispose() {
    next.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final value = next.text.trim().toLowerCase();
    if (!value.contains('@')) {
      setState(() {});
      return;
    }
    setState(() => saving = true);
    final db = DatabaseHelper();
    final auth = context.read<AuthProvider>();
    final appState = context.read<AppStateProvider>();
    final existing = await db.getUser(value);
    if (!mounted) return;
    if (existing != null) {
      setState(() => saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This email is already used by another account'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }
    await db.updateUserEmail(auth.userEmail, value);
    auth.updateEmail(value);
    await appState.saveAuthSession(
      auth.userId,
      auth.userName,
      value,
      auth.tier,
      role: auth.role.name,
    );
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Email updated successfully')));
  }

  @override
  Widget build(BuildContext context) {
    final isLarge = _usesLargeText(context);
    return _Sheet(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Handle(),
            Text(
              'Update Email Address',
              style: AppTheme.textStyle(
                fontSize: isLarge ? 30 : 25,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'We will use your new email the next time you sign in.',
              style: AppTheme.textStyle(
                fontSize: isLarge ? 18 : 15,
                color: AppTheme.secondaryTextColor(context),
              ),
            ),
            const SizedBox(height: 22),
            TextField(
              controller: TextEditingController(text: widget.email),
              readOnly: true,
              decoration: _input(
                context,
                'Current Email',
                Icons.email_outlined,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: next,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              onChanged: (_) => setState(() {}),
              decoration:
                  _input(
                    context,
                    'New Email',
                    Icons.alternate_email_rounded,
                  ).copyWith(
                    suffixIcon: next.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear_rounded),
                            onPressed: () => setState(next.clear),
                          ),
                  ),
            ),
            const SizedBox(height: 22),
            FilledButton(
              onPressed: saving ? null : save,
              style: _button(context),
              child: Text(saving ? 'Updating…' : 'Update Email'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PasswordSheet extends StatefulWidget {
  const _PasswordSheet();
  @override
  State<_PasswordSheet> createState() => _PasswordSheetState();
}

class _PasswordSheetState extends State<_PasswordSheet> {
  final current = TextEditingController(),
      next = TextEditingController(),
      confirm = TextEditingController();
  bool a = false, b = false, c = false, saving = false;
  bool get length => next.text.length >= 8;
  bool get number => RegExp(r'\d').hasMatch(next.text);
  bool get special => RegExp(r'[^A-Za-z0-9]').hasMatch(next.text);
  bool get valid =>
      current.text.isNotEmpty &&
      length &&
      number &&
      special &&
      next.text == confirm.text;
  @override
  void dispose() {
    current.dispose();
    next.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!valid) return;
    setState(() => saving = true);
    final auth = context.read<AuthProvider>();
    final user = await DatabaseHelper().getUser(auth.userEmail);
    final ok = DatabaseHelper().verifyPassword(
      current.text,
      user?['password'] as String? ?? '',
    );
    if (!mounted) return;
    if (!ok) {
      setState(() => saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Your current password is incorrect'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }
    await DatabaseHelper().updateUserPassword(auth.userEmail, next.text);
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Password updated successfully')),
    );
  }

  Widget field(
    String label,
    TextEditingController ctrl,
    bool visible,
    VoidCallback toggle,
  ) => TextField(
    controller: ctrl,
    obscureText: !visible,
    onChanged: (_) => setState(() {}),
    decoration: _input(context, label, Icons.lock_outline_rounded).copyWith(
      suffixIcon: IconButton(
        icon: Icon(
          visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        ),
        onPressed: toggle,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final isLarge = _usesLargeText(context);
    return _Sheet(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Handle(),
              Text(
                'Update Password',
                style: AppTheme.textStyle(
                  fontSize: isLarge ? 30 : 25,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Use a unique password you do not use elsewhere.',
                style: AppTheme.textStyle(
                  fontSize: isLarge ? 18 : 15,
                  color: AppTheme.secondaryTextColor(context),
                ),
              ),
              const SizedBox(height: 20),
              field(
                'Current Password',
                current,
                a,
                () => setState(() => a = !a),
              ),
              const SizedBox(height: 12),
              field('New Password', next, b, () => setState(() => b = !b)),
              const SizedBox(height: 12),
              field(
                'Confirm New Password',
                confirm,
                c,
                () => setState(() => c = !c),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _Rule('8+ characters', length),
                  _Rule('1 number', number),
                  _Rule('1 special character', special),
                ],
              ),
              const SizedBox(height: 22),
              FilledButton(
                onPressed: valid && !saving ? save : null,
                style: _button(context),
                child: Text(saving ? 'Updating…' : 'Update Password'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Rule extends StatelessWidget {
  const _Rule(this.label, this.ok);
  final String label;
  final bool ok;
  @override
  Widget build(BuildContext context) {
    final isLarge = _usesLargeText(context);
    final color = ok
        ? AppTheme.actionColor(context)
        : AppTheme.secondaryTextColor(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            ok ? Icons.check_circle_rounded : Icons.circle_outlined,
            size: isLarge ? 20 : 16,
            color: color,
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: AppTheme.textStyle(
              fontSize: isLarge ? 15 : 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _SubscriptionSheet extends StatefulWidget {
  const _SubscriptionSheet();
  @override
  State<_SubscriptionSheet> createState() => _SubscriptionSheetState();
}

class _SubscriptionSheetState extends State<_SubscriptionSheet> {
  SubscriptionPlan selected = SubscriptionService.guardianAnnual;
  bool loading = false;
  Future<void> checkout() async {
    setState(() => loading = true);
    try {
      final opened = await SubscriptionService().openCheckout(selected);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            opened
                ? 'Checkout opened. Complete your payment to activate your plan.'
                : 'Checkout could not be opened. Please try again.',
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('We could not start checkout. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLarge = _usesLargeText(context);
    final ink = AppTheme.actionColor(context);
    final muted = AppTheme.secondaryTextColor(context);
    return _Sheet(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 22),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Handle(),
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: ink.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    'MEDISENSE PRO',
                    style: AppTheme.textStyle(
                      fontSize: isLarge ? 15 : 12,
                      fontWeight: FontWeight.w900,
                      color: ink,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Upgrade your family’s medicine support',
                textAlign: TextAlign.center,
                style: AppTheme.textStyle(
                  fontSize: isLarge ? 31 : 26,
                  height: 1.12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Smart offline scanning is included. Pro adds extra help for difficult labels and families.',
                textAlign: TextAlign.center,
                style: AppTheme.textStyle(
                  fontSize: isLarge ? 18 : 15,
                  height: 1.35,
                  color: muted,
                ),
              ),
              const SizedBox(height: 20),
              _Plan(
                SubscriptionService.premiumMonthly,
                selected.id == SubscriptionService.premiumMonthly.id,
                () => setState(
                  () => selected = SubscriptionService.premiumMonthly,
                ),
              ),
              const SizedBox(height: 10),
              _Plan(
                SubscriptionService.guardianAnnual,
                selected.id == SubscriptionService.guardianAnnual.id,
                () => setState(
                  () => selected = SubscriptionService.guardianAnnual,
                ),
                best: true,
              ),
              const SizedBox(height: 20),
              ...const [
                'Unlimited cloud scans',
                'Guardian family dashboard',
                'Priority medication alerts',
                'Custom voice profiles',
              ].map(
                (f) => Padding(
                  padding: const EdgeInsets.only(bottom: 9),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_rounded, size: 20, color: ink),
                      const SizedBox(width: 10),
                      Text(
                        f,
                        style: AppTheme.textStyle(
                          fontSize: isLarge ? 18 : 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: loading ? null : checkout,
                style: _button(context),
                child: Text(
                  loading
                      ? 'Opening secure checkout…'
                      : 'Continue with ${selected.title}',
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'By continuing, you agree to the Terms of Service. You can cancel renewal anytime.',
                textAlign: TextAlign.center,
                style: AppTheme.textStyle(
                  fontSize: isLarge ? 15 : 12,
                  color: muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Plan extends StatelessWidget {
  const _Plan(this.plan, this.selected, this.onTap, {this.best = false});
  final SubscriptionPlan plan;
  final bool selected, best;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final isLarge = _usesLargeText(context);
    final ink = AppTheme.actionColor(context);
    final muted = AppTheme.secondaryTextColor(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: EdgeInsets.all(isLarge ? 18 : 15),
        decoration: BoxDecoration(
          color: selected ? ink.withValues(alpha: .09) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? ink : AppTheme.timber,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              color: ink,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          plan.title,
                          style: AppTheme.textStyle(
                            fontSize: isLarge ? 20 : 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (best)
                        Container(
                          margin: const EdgeInsets.only(left: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.foil.withValues(alpha: .18),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            'BEST VALUE',
                            style: AppTheme.textStyle(
                              fontSize: isLarge ? 12 : 10,
                              fontWeight: FontWeight.w900,
                              color: AppTheme.foil,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    plan.description,
                    style: AppTheme.textStyle(
                      fontSize: isLarge ? 16 : 12,
                      color: muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              plan.price,
              textAlign: TextAlign.end,
              style: AppTheme.textStyle(
                fontSize: isLarge ? 17 : 14,
                fontWeight: FontWeight.w800,
                color: ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle();
  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 42,
      height: 4,
      margin: const EdgeInsets.only(top: 12, bottom: 18),
      decoration: BoxDecoration(
        color: AppTheme.secondaryTextColor(context).withValues(alpha: .4),
        borderRadius: BorderRadius.circular(99),
      ),
    ),
  );
}

InputDecoration _input(BuildContext context, String label, IconData icon) =>
    InputDecoration(
      labelText: label,
      labelStyle: AppTheme.textStyle(
        fontSize: _usesLargeText(context) ? 17 : 14,
      ),
      prefixIcon: Icon(icon),
      contentPadding: EdgeInsets.symmetric(
        horizontal: 16,
        vertical: _usesLargeText(context) ? 20 : 16,
      ),
      filled: true,
      fillColor: Theme.of(context).brightness == Brightness.dark
          ? AppTheme.darkMuted
          : AppTheme.muted,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: AppTheme.timber),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: AppTheme.actionColor(context), width: 2),
      ),
    );
ButtonStyle _button(BuildContext context) => FilledButton.styleFrom(
  minimumSize: Size.fromHeight(_usesLargeText(context) ? 64 : 54),
  backgroundColor: Theme.of(context).brightness == Brightness.dark
      ? AppTheme.darkAccentGreen
      : AppTheme.ink,
  foregroundColor: AppTheme.actionForegroundColor(context),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
  textStyle: AppTheme.textStyle(
    fontSize: _usesLargeText(context) ? 20 : 16,
    fontWeight: FontWeight.w800,
  ),
);
