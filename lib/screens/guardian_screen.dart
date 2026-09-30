import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';
import '../providers/medication_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/tts_provider.dart';
import '../services/supabase_sync_service.dart';
import '../services/greeting_name.dart';
import '../models/user.dart';
import '../data/database_helper.dart';
import '../providers/app_state_provider.dart';
import '../models/accessibility_mode.dart';
import '../widgets/medi_bottom_nav.dart';
import '../widgets/care_patient_dashboard.dart';

class GuardianScreen extends StatefulWidget {
  const GuardianScreen({super.key});

  @override
  State<GuardianScreen> createState() => _GuardianScreenState();
}

class _GuardianScreenState extends State<GuardianScreen> {
  bool _hasGreeted = false;
  List<PairingRecord> _pairings = [];
  bool _loadingPairings = true;

  bool get _usesLargeText =>
      context.read<AppStateProvider>().accessibilityMode.usesLargeText;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_hasGreeted) {
      final auth = context.watch<AuthProvider>();
      final appState = context.read<AppStateProvider>();
      if (appState.savedUserId != null && !auth.isLoggedIn) return;
      final tts = context.read<TtsProvider>();
      final name = resolveGreetingName([
        if (auth.isLoggedIn) auth.userName,
        appState.savedUserName,
        appState.onboardingName,
      ]);
      tts.speak(
        name == null
            ? 'This is the guardian dashboard.'
            : 'Hello $name, this is the guardian dashboard.',
        name == null
            ? 'Ito ang pangunahing pahina para sa tagapag-alaga.'
            : 'Kumusta, $name. Ito ang pangunahing pahina para sa tagapag-alaga.',
      );
      _hasGreeted = true;
    }
    _loadPairings();
  }

  Future<void> _loadPairings() async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      setState(() => _loadingPairings = false);
      return;
    }

    final db = DatabaseHelper();
    final localPairings = auth.isGuardian
        ? await db.getPairingsForGuardian(auth.userId)
        : await db.getPairingsForPatient(auth.userId);
    final pairingsById = {
      for (final record in localPairings) record.id: record,
    };
    try {
      final remotePairings = await SupabaseSyncService().fetchPairingRequests(
        userId: auth.userId,
        userEmail: auth.userEmail,
      );
      // The server is authoritative after a successful refresh. A locally
      // cached accepted pairing may have been revoked on another device.
      pairingsById.clear();
      for (final record in remotePairings) {
        pairingsById[record.id] = record;
        await db.insertPairing(record);
      }
    } catch (error) {
      debugPrint('PairingSync: could not refresh requests - $error');
    }
    final pairings = pairingsById.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    if (mounted) {
      setState(() {
        _pairings = pairings;
        _loadingPairings = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    if (!auth.isLoggedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        context.go('/auth');
      });
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final mode = context.watch<AppStateProvider>().accessibilityMode;
    final isLarge = mode.usesLargeText;
    final isVisionLoss = mode.isVisionLoss;
    final page = AppTheme.pageColor(context);
    final primary = AppTheme.primaryTextColor(context);
    final pendingPairings = _pairings
        .where((p) => p.status == PairingStatus.pending)
        .toList();
    final acceptedPairings = _pairings
        .where((p) => p.status == PairingStatus.accepted)
        .toList();

    final listChildren = <Widget>[
      if (auth.isGuardian && acceptedPairings.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            'Your patients',
            style: AppTheme.textStyle(
              fontSize: isLarge ? 24 : 20,
              fontWeight: FontWeight.w700,
              color: primary,
            ),
          ),
        )
      else ...[
        _buildHeader(context),
        const SizedBox(height: 20),
      ],
      if (auth.isPatient && pendingPairings.isNotEmpty) ...[
        _buildPendingRequests(pendingPairings),
        const SizedBox(height: 20),
      ],
      if (acceptedPairings.isEmpty) ...[
        _buildEmptyState(context),
        if (auth.isGuardian) ...[
          const SizedBox(height: 14),
          _buildBenefitsStrip(context),
        ],
      ] else ...[
        ...acceptedPairings.map((p) => _buildPairedPatientCard(context, p)),
      ],
      const SizedBox(height: 32),
    ];

    return Scaffold(
      backgroundColor: page,
      appBar: AppBar(
        backgroundColor: page,
        foregroundColor: primary,
        elevation: 0,
        centerTitle: true,
        toolbarHeight: isLarge ? 80 : 76,
        title: Text(
          'MediSense',
          style: AppTheme.textStyle(
            fontSize: isLarge ? 30 : 26,
            fontWeight: FontWeight.w800,
            color: primary,
          ),
        ),
        actions: [
          if (auth.isGuardian && acceptedPairings.isNotEmpty)
            IconButton(
              tooltip: 'Pair with another patient',
              onPressed: _showPairDialog,
              icon: Icon(
                Icons.person_add_alt_1_rounded,
                size: isLarge ? 28 : 24,
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: MediBottomNav(
        currentRoute: '/guardian',
        large: isLarge,
        visionLoss: isVisionLoss,
      ),
      body: SafeArea(
        child: _loadingPairings
            ? Center(
                child: CircularProgressIndicator(
                  color: Theme.of(context).colorScheme.primary,
                ),
              )
            : ListView(
                padding: EdgeInsets.fromLTRB(20, 12, 20, isLarge ? 200 : 168),
                children: listChildren,
              ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final isLarge = _usesLargeText;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = AppTheme.surfaceColor(context);
    final border = AppTheme.borderColor(context);
    final label = auth.isGuardian ? 'Care Team Dashboard' : 'My Guardians';
    return Container(
      padding: EdgeInsets.all(isLarge ? 22 : 18),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isDark ? border : const Color(0xFFEAE6DF),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.12 : 0.04),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (auth.isGuardian) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: isLarge ? 14 : 12,
                  vertical: isLarge ? 6 : 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF556B4F),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'GUARDIAN',
                  style: AppTheme.textStyle(
                    color: Colors.white,
                    fontSize: isLarge ? 14 : 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
            SizedBox(height: isLarge ? 14 : 10),
          ],
          Row(
            children: [
              Container(
                width: isLarge ? 72 : 64,
                height: isLarge ? 72 : 64,
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.darkMuted : const Color(0xFFEEF2EC),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: EdgeInsets.all(isLarge ? 18 : 16),
                  child: Icon(
                    Icons.person_rounded,
                    color: isDark
                        ? AppTheme.darkAccentGreen
                        : const Color(0xFF4A5D4E),
                    size: isLarge ? 36 : 32,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      resolveGreetingName([
                            if (auth.isLoggedIn) auth.userName,
                            context.read<AppStateProvider>().savedUserName,
                            context.read<AppStateProvider>().onboardingName,
                          ]) ??
                          (context.read<AppStateProvider>().isFilipino
                              ? 'Kaibigan'
                              : 'There'),
                      softWrap: true,
                      style: AppTheme.textStyle(
                        color: AppTheme.primaryTextColor(context),
                        fontSize: isLarge ? 25 : 20,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.3,
                        height: 1.15,
                      ),
                    ),
                    SizedBox(height: isLarge ? 6 : 4),
                    Text(
                      label,
                      style: AppTheme.textStyle(
                        color: AppTheme.secondaryTextColor(context),
                        fontSize: isLarge ? 18 : 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPairNewPatientButton({String label = 'Pair with a Patient'}) {
    const moss = Color(0xFF4A5D4E);
    final isLarge = _usesLargeText;
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: _showPairDialog,
        style: FilledButton.styleFrom(
          backgroundColor: moss,
          foregroundColor: Colors.white,
          elevation: 4,
          shadowColor: moss.withValues(alpha: 0.28),
          shape: const StadiumBorder(),
          minimumSize: Size.fromHeight(isLarge ? 60 : 50),
          padding: EdgeInsets.symmetric(
            horizontal: isLarge ? 16 : 20,
            vertical: isLarge ? 12 : 10,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person_add_alt_1_rounded, size: isLarge ? 26 : 21),
            SizedBox(width: isLarge ? 12 : 10),
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                softWrap: true,
                style: AppTheme.textStyle(
                  fontSize: isLarge ? 20 : 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showPairDialog() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PairPatientSheet(onRequestSent: _loadPairings),
    );
  }

  Widget _buildPendingRequests(List<PairingRecord> pending) {
    final primary = AppTheme.primaryTextColor(context);
    final secondary = AppTheme.secondaryTextColor(context);
    final isLarge = _usesLargeText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.notifications_active_rounded,
              color: AppTheme.warning,
              size: isLarge ? 28 : 22,
            ),
            const SizedBox(width: 8),
            Text(
              'Pending Requests',
              style: AppTheme.textStyle(
                fontSize: isLarge ? 22 : 18,
                fontWeight: FontWeight.w700,
                color: primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ...pending.map((p) {
          final identity = Row(
            children: [
              Container(
                width: isLarge ? 52 : 44,
                height: isLarge ? 52 : 44,
                decoration: BoxDecoration(
                  color: AppTheme.warning.withValues(alpha: 20 / 255),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.person_add_rounded,
                  color: AppTheme.warning,
                  size: isLarge ? 28 : 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.guardianEmail,
                      style: AppTheme.textStyle(
                        fontSize: isLarge ? 18 : 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'Wants to connect to your MediSense account.',
                      style: AppTheme.textStyle(
                        fontSize: isLarge ? 18 : 12,
                        height: 1.35,
                        color: secondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
          final actions = Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: [
              TextButton(
                onPressed: () => _acceptPairing(p),
                style: TextButton.styleFrom(
                  minimumSize: Size(48, isLarge ? 56 : 48),
                ),
                child: Text(
                  'ACCEPT',
                  style: TextStyle(fontSize: isLarge ? 18 : 14),
                ),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: () => _rejectPairing(p),
                style: TextButton.styleFrom(
                  minimumSize: Size(48, isLarge ? 56 : 48),
                ),
                child: Text(
                  'DECLINE',
                  style: TextStyle(
                    color: AppTheme.error,
                    fontSize: isLarge ? 18 : 14,
                  ),
                ),
              ),
            ],
          );
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: EdgeInsets.all(isLarge ? 20 : 16),
              child: isLarge
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        identity,
                        const SizedBox(height: 8),
                        Align(alignment: Alignment.centerRight, child: actions),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(child: identity),
                        actions,
                      ],
                    ),
            ),
          );
        }),
      ],
    );
  }

  Future<void> _acceptPairing(PairingRecord record) async {
    final db = DatabaseHelper();
    final sync = SupabaseSyncService();
    final appState = context.read<AppStateProvider>();
    try {
      await sync.updatePairingStatus(
        record.id,
        PairingStatus.accepted,
        patientId: record.patientId,
      );
      await db.updatePairingStatus(record.id, PairingStatus.accepted);
      if (appState.pendingPairingId == record.id) {
        await appState.setPendingPairingId(null);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not accept the request. Please try again.'),
          ),
        );
      }
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Paired successfully! This Guardian can now see your medication schedule.',
          ),
          backgroundColor: AppTheme.success,
        ),
      );
      _loadPairings();
    }
  }

  Future<void> _rejectPairing(PairingRecord record) async {
    final db = DatabaseHelper();
    final sync = SupabaseSyncService();
    try {
      await sync.updatePairingStatus(
        record.id,
        PairingStatus.rejected,
        patientId: record.patientId,
      );
      await db.updatePairingStatus(record.id, PairingStatus.rejected);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not decline the request. Please try again.'),
          ),
        );
      }
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Pairing declined.')));
      _loadPairings();
    }
  }

  Widget _buildPairedPatientCard(BuildContext context, PairingRecord pairing) {
    final auth = context.read<AuthProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLarge = _usesLargeText;
    final accent = isDark ? AppTheme.darkAccentGreen : AppTheme.accentGreen;
    final secondary = AppTheme.secondaryTextColor(context);
    final displayEmail = auth.isGuardian
        ? pairing.patientEmail
        : pairing.guardianEmail;
    final displayRole = auth.isGuardian ? 'Patient' : 'Guardian';

    final identityCard = Card(
      margin: const EdgeInsets.only(bottom: 14),
      color: AppTheme.surfaceColor(context),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: AppTheme.borderColor(context)),
      ),
      child: Padding(
        padding: EdgeInsets.all(isLarge ? 22 : 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: isLarge ? 56 : 48,
                  height: isLarge ? 56 : 48,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.13),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.person_rounded,
                    color: accent,
                    size: isLarge ? 32 : 28,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$displayRole - Connected',
                        style: TextStyle(
                          fontSize: isLarge ? 18 : 13,
                          height: 1.3,
                          color: accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (auth.isGuardian)
                  PopupMenuButton<String>(
                    iconSize: isLarge ? 28 : 24,
                    padding: EdgeInsets.all(isLarge ? 14 : 12),
                    onSelected: (action) {
                      if (action == 'unpair') {
                        _confirmUnpair(pairing);
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'unpair',
                        child: Row(
                          children: [
                            Icon(Icons.link_off_rounded, size: 20),
                            SizedBox(width: 8),
                            Text('Unpair'),
                          ],
                        ),
                      ),
                    ],
                  )
                else
                  PopupMenuButton<String>(
                    iconSize: isLarge ? 28 : 24,
                    padding: EdgeInsets.all(isLarge ? 14 : 12),
                    onSelected: (action) {
                      if (action == 'stop') {
                        _confirmUnpair(pairing);
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'stop',
                        child: Row(
                          children: [
                            Icon(Icons.link_off_rounded, size: 20),
                            SizedBox(width: 8),
                            Text('Stop sharing'),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 12),
            // Give long addresses the full card width. Horizontal scrolling
            // preserves the full address and accessible font size on phones.
            Semantics(
              label: '$displayRole email: $displayEmail',
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  displayEmail,
                  maxLines: 1,
                  softWrap: false,
                  style: AppTheme.textStyle(
                    fontSize: isLarge ? 20 : 15,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primaryTextColor(context),
                  ),
                ),
              ),
            ),
            if (!auth.isGuardian) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    Icons.visibility_outlined,
                    size: isLarge ? 24 : 18,
                    color: secondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Guardian can see your medication schedule and doses taken.',
                      style: AppTheme.textStyle(
                        fontSize: isLarge ? 16 : 13,
                        color: secondary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
    if (!auth.isGuardian) return identityCard;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        identityCard,
        const SizedBox(height: 8),
        _buildPatientSummary(pairing.patientId),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildPatientSummary(String patientId) {
    return CarePatientDashboard(patientId: patientId, large: _usesLargeText);
  }

  void _confirmUnpair(PairingRecord pairing) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Pairing'),
        content: Text(
          'Are you sure you want to stop monitoring ${pairing.patientEmail}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              await DatabaseHelper().updatePairingStatus(
                pairing.id,
                PairingStatus.rejected,
              );
              await SupabaseSyncService().removePairing(
                guardianId: pairing.guardianId,
                patientId: pairing.patientId,
              );
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              if (mounted) {
                context.read<AuthProvider>().clearPairedPatient();
                context.read<MedicationProvider>().viewOwnMedications();
                _loadPairings();
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final isGuardian = auth.isGuardian;
    final isLarge = _usesLargeText;
    final accent = AppTheme.actionColor(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(isLarge ? 28 : 24),
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor(context),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isDark
              ? AppTheme.borderColor(context)
              : const Color(0xFFEAE6DF),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.12 : 0.04),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: isLarge ? 76 : 64,
            height: isLarge ? 76 : 64,
            decoration: BoxDecoration(
              color: isDark ? AppTheme.darkMuted : const Color(0xFFF1F4EE),
              shape: BoxShape.circle,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  Icons.people_alt_rounded,
                  size: isLarge ? 40 : 34,
                  color: isDark
                      ? AppTheme.darkAccentGreen
                      : const Color(0xFF4A5D4E),
                ),
                Positioned(
                  right: 9,
                  bottom: 10,
                  child: Icon(
                    Icons.add_circle_rounded,
                    size: isLarge ? 20 : 17,
                    color: isDark ? AppTheme.darkTextPrimary : Colors.white,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: isLarge ? 18 : 14),
          Text(
            isGuardian
                ? 'No Patients Connected Yet'
                : 'No Guardians Connected Yet',
            textAlign: TextAlign.center,
            style: AppTheme.textStyle(
              fontSize: isLarge ? 24 : 18,
              fontWeight: FontWeight.w600,
              color: AppTheme.primaryTextColor(context),
            ),
          ),
          SizedBox(height: isLarge ? 12 : 8),
          Text(
            isGuardian
                ? 'Link your account with a dependent or family member to track their medication adherence in real time.'
                : 'Ask your Guardian to use the email on your MediSense account. When an invitation arrives, review and accept it here.',
            textAlign: TextAlign.center,
            style: AppTheme.textStyle(
              fontSize: isLarge ? 18 : 14,
              height: 1.5,
              color: Theme.of(context).brightness == Brightness.dark
                  ? AppTheme.secondaryTextColor(context)
                  : const Color(0xFF6B7280),
            ),
          ),
          if (isGuardian) ...[
            SizedBox(height: isLarge ? 22 : 18),
            _buildPairNewPatientButton(),
            SizedBox(height: isLarge ? 8 : 4),
            TextButton(
              onPressed: _showPairingHelp,
              style: TextButton.styleFrom(
                minimumSize: Size(48, isLarge ? 56 : 44),
                foregroundColor: accent,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: Text(
                'How pairing works →',
                style: AppTheme.textStyle(
                  fontSize: isLarge ? 17 : 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.secondaryTextColor(context),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBenefitsStrip(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLarge = _usesLargeText;
    final accent = isDark ? AppTheme.darkAccentGreen : const Color(0xFF4A5D4E);
    final tint = isDark ? AppTheme.darkMuted : const Color(0xFFF1F4EE);

    Widget benefit(IconData icon, String label) {
      return Expanded(
        child: Container(
          constraints: BoxConstraints(minHeight: isLarge ? 144 : 112),
          padding: EdgeInsets.all(isLarge ? 18 : 14),
          decoration: BoxDecoration(
            color: tint,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppTheme.borderColor(context)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: isLarge ? 28 : 22, color: accent),
              const SizedBox(height: 10),
              Text(
                label,
                style: AppTheme.textStyle(
                  fontSize: isLarge ? 18 : 13,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.primaryTextColor(context),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          benefit(
            Icons.notifications_active_outlined,
            'Instant Missed-Dose Alerts',
          ),
          const SizedBox(width: 12),
          benefit(Icons.analytics_outlined, 'Adherence Reports & Logs'),
        ],
      ),
    );
  }

  Future<void> _showPairingHelp() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLarge = _usesLargeText;
    final shouldOpenPairing = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: AppTheme.surfaceColor(context),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'How pairing works',
                style: AppTheme.textStyle(
                  fontSize: isLarge ? 30 : 22,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primaryTextColor(context),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Send a pairing request using the patient’s account email. They must accept it before their medication schedule appears on your dashboard.',
                style: AppTheme.textStyle(
                  fontSize: isLarge ? 20 : 15,
                  height: 1.5,
                  color: AppTheme.secondaryTextColor(context),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: isLarge ? 60 : 52,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: isDark
                        ? AppTheme.darkAccentGreen
                        : const Color(0xFF4A5D4E),
                    foregroundColor: isDark
                        ? AppTheme.darkPrimaryForeground
                        : Colors.white,
                    shape: const StadiumBorder(),
                  ),
                  child: Text(
                    'Pair with a Patient',
                    style: AppTheme.textStyle(
                      fontSize: isLarge ? 20 : 14,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? AppTheme.darkPrimaryForeground
                          : Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // Wait for the help sheet's route to finish dismissing before presenting
    // the pairing sheet. Pushing a second modal during the first route's pop
    // can leave an active dirty element in the wrong build scope.
    if (shouldOpenPairing == true && mounted) {
      await _showPairDialog();
    }
  }
}

class _PairPatientSheet extends StatefulWidget {
  const _PairPatientSheet({required this.onRequestSent});

  final VoidCallback onRequestSent;

  @override
  State<_PairPatientSheet> createState() => _PairPatientSheetState();
}

class _PairPatientSheetState extends State<_PairPatientSheet> {
  final _emailController = TextEditingController();
  bool _sending = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  bool get _canUpdateSheet {
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    final animationStatus = route?.animation?.status;
    return route?.isCurrent == true &&
        animationStatus != AnimationStatus.reverse &&
        animationStatus != AnimationStatus.dismissed;
  }

  Future<void> _submit() async {
    if (_sending) return;
    final email = _emailController.text.trim().toLowerCase();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _errorMessage = 'Enter a valid email address.');
      return;
    }

    setState(() {
      _sending = true;
      _errorMessage = null;
    });

    final messenger = ScaffoldMessenger.of(context);
    try {
      final sync = SupabaseSyncService();
      await sync.sendPairingInvitation(email);
      if (!mounted || !_canUpdateSheet) return;

      FocusScope.of(context).unfocus();
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: const Text(
            'If this address belongs to a patient, they will receive an invitation to review.',
          ),
          backgroundColor: AppTheme.success,
          duration: const Duration(seconds: 4),
        ),
      );
      widget.onRequestSent();
    } catch (error) {
      if (!_canUpdateSheet) return;
      setState(() {
        _sending = false;
        _errorMessage = error
            .toString()
            .replaceFirst('Bad state: ', '')
            .replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLarge = context
        .watch<AppStateProvider>()
        .accessibilityMode
        .usesLargeText;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = AppTheme.surfaceColor(context);
    final primary = AppTheme.primaryTextColor(context);
    final secondary = AppTheme.secondaryTextColor(context);
    final fieldFill = isDark
        ? AppTheme.darkInputSurface
        : const Color(0xFFF9F8F6);
    final focusColor = isDark
        ? AppTheme.darkAccentGreen
        : const Color(0xFF4A5D4E);
    final borderColor = AppTheme.borderColor(context);

    return AnimatedPadding(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        decoration: BoxDecoration(
          color: surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              isLarge ? 28 : 24,
              12,
              isLarge ? 28 : 24,
              20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 44,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: isDark
                              ? AppTheme.darkBorder
                              : const Color(0xFFD1D5DB),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      Positioned(
                        right: 0,
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: IconButton(
                            tooltip: 'Close pairing sheet',
                            onPressed: () => Navigator.of(context).pop(),
                            style: IconButton.styleFrom(
                              backgroundColor: fieldFill,
                              foregroundColor: secondary,
                              shape: const CircleBorder(),
                            ),
                            icon: const Icon(Icons.close_rounded, size: 21),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Pair with a Patient',
                  style: AppTheme.textStyle(
                    fontSize: isLarge ? 30 : 20,
                    fontWeight: FontWeight.w600,
                    color: primary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Enter the email address of the patient you want to monitor. They will receive an invitation request.',
                  style: AppTheme.textStyle(
                    fontSize: isLarge ? 20 : 14,
                    height: 1.45,
                    color: secondary,
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  "Patient's Email Address",
                  style: AppTheme.textStyle(
                    fontSize: isLarge ? 20 : 14,
                    fontWeight: FontWeight.w600,
                    color: primary,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _emailController,
                  autofocus: true,
                  keyboardType: TextInputType.emailAddress,
                  textCapitalization: TextCapitalization.none,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.email],
                  enabled: !_sending,
                  style: AppTheme.textStyle(
                    color: primary,
                    fontSize: isLarge ? 19 : 16,
                  ),
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    hintText: 'patient@example.com',
                    hintStyle: AppTheme.textStyle(
                      color: secondary.withValues(alpha: 0.8),
                      fontSize: isLarge ? 17 : 15,
                    ),
                    prefixIcon: Icon(
                      Icons.mail_outline_rounded,
                      color: secondary,
                    ),
                    filled: true,
                    fillColor: fieldFill,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: isLarge ? 20 : 16,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: focusColor, width: 1.5),
                    ),
                    errorText: _errorMessage,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  height: isLarge ? 60 : 52,
                  child: FilledButton(
                    onPressed: _sending ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: focusColor,
                      foregroundColor: isDark
                          ? AppTheme.darkPrimaryForeground
                          : Colors.white,
                      disabledBackgroundColor: focusColor.withValues(
                        alpha: 0.55,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _sending
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          )
                        : Text(
                            'Send Request',
                            style: AppTheme.textStyle(
                              fontSize: isLarge ? 20 : 16,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? AppTheme.darkPrimaryForeground
                                  : Colors.white,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
