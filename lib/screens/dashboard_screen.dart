import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../theme/app_theme.dart';
import '../models/accessibility_mode.dart';
import '../models/medication.dart';
import '../providers/medication_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/tts_provider.dart';
import '../providers/app_state_provider.dart';
import '../providers/notification_provider.dart';
import '../widgets/medication_card.dart';
import '../widgets/elder_bottom_nav.dart';
import '../services/accessibility_feedback.dart';
import '../services/greeting_name.dart';
import '../widgets/medi_bottom_nav.dart';
import '../widgets/medicine_bottle_illustration.dart';
import '../widgets/guardian_home_card.dart';
import '../widgets/patient_guardian_home_card.dart';
import '../widgets/care_reminder_inbox.dart';

const List<String> _timeBlockIds = ScheduleTime.blocks;

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with AutomaticKeepAliveClientMixin {
  bool _hasGreeted = false;
  String _selectedBlock = 'all';

  @override
  bool get wantKeepAlive => true;

  void _announceArrival(
    MedicationProvider provider,
    AuthProvider authProvider,
    AppStateProvider appState,
  ) {
    if (_hasGreeted || provider.isLoading) return;
    // A saved session is restored shortly after the first frame. Wait for
    // AuthProvider to receive it instead of greeting the user by the guest
    // onboarding name.
    if (appState.savedUserId != null && !authProvider.isLoggedIn) return;
    _hasGreeted = true;
    if (appState.ttsVerbosity == TtsVerbosity.essential) return;
    final next = _findNextDose(provider);
    final name = resolveGreetingName([
      if (authProvider.isLoggedIn) authProvider.userName,
      appState.savedUserName,
      appState.onboardingName,
    ]);
    final englishGreeting = name == null ? 'Hello' : 'Hello $name';
    final filipinoGreeting = name == null ? 'Kumusta' : 'Kumusta, $name';
    var english = authProvider.isGuardian
        ? '$englishGreeting. Here is your care dashboard.'
        : next == null
        ? '$englishGreeting. You have no medicine scheduled right now.'
        : '$englishGreeting. Take ${next.med.name} at ${next.s.formattedTime}.';
    var filipino = authProvider.isGuardian
        ? '$filipinoGreeting. Narito ang iyong care dashboard.'
        : next == null
        ? '$filipinoGreeting. Wala kang nakatakdang gamot sa ngayon.'
        : '$filipinoGreeting. Inumin ang ${next.med.name} sa ${next.s.formattedTime}.';
    if (appState.ttsVerbosity == TtsVerbosity.detailed) {
      if (authProvider.isGuardian) {
        english +=
            ' Your guardian dashboard shows care reminders and connected patients.';
        filipino +=
            ' Nasa guardian dashboard ang mga paalala at konektadong pasyente.';
      } else {
        english +=
            ' Open Schedule for all doses, or tap the microphone for help.';
        filipino +=
            ' Buksan ang Iskedyul para sa lahat ng gamot, o pindutin ang mikropono para sa tulong.';
      }
    }
    final tts = context.read<TtsProvider>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) tts.speak(english, filipino);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final provider = context.watch<MedicationProvider>();
    final authProvider = context.watch<AuthProvider>();
    final appState = context.watch<AppStateProvider>();
    final mode = appState.accessibilityMode;
    final isVisionLoss = mode.isVisionLoss;
    final usesElderLayout = mode.isElder || isVisionLoss;

    _announceArrival(provider, authProvider, appState);

    if (usesElderLayout) {
      return _buildElderDashboard(provider, authProvider);
    }
    return _buildStandardDashboard(provider, authProvider);
  }

  // ── Shared helpers ────────────────────────────────────────────────────────

  ({Medication med, ScheduleTime s})? _findNextDose(
    MedicationProvider provider,
  ) {
    final pending = <({Medication med, ScheduleTime s})>[];
    for (final m in provider.medications) {
      for (final s in m.schedule) {
        if (!s.taken) pending.add((med: m, s: s));
      }
    }
    if (pending.isEmpty) return null;
    pending.sort((a, b) {
      final ca = _timeInMinutes(a.s.time);
      final cb = _timeInMinutes(b.s.time);
      return ca.compareTo(cb);
    });
    return pending.first;
  }

  List<_BlockCell> _buildBlocks(
    MedicationProvider provider,
    ({Medication med, ScheduleTime s})? next,
  ) {
    final allDoses = <({Medication med, ScheduleTime s})>[];
    for (final m in provider.medications) {
      for (final s in m.schedule) {
        allDoses.add((med: m, s: s));
      }
    }
    final now = _timeInMinutes(TimeOfDay.now());

    final cells = <_BlockCell>[];
    var total = 0;
    var taken = 0;
    for (final block in _timeBlockIds) {
      final inBlock = allDoses.where((d) => d.s.label == block).toList();
      final takenInBlock = inBlock.where((d) => d.s.taken).length;
      final hasMissed = inBlock.any(
        (d) => !d.s.taken && _timeInMinutes(d.s.time) < now,
      );
      cells.add(
        _BlockCell(
          id: block,
          label: block,
          count: inBlock.length,
          taken: takenInBlock,
          isNow: next != null && next.s.label == block,
          hasMissed: hasMissed,
        ),
      );
      total += inBlock.length;
      taken += takenInBlock;
    }

    final pending = total - taken;
    cells.insert(
      0,
      _BlockCell(
        id: 'all',
        label: 'All',
        count: total,
        taken: taken,
        isNow: false,
        hasMissed: pending > 0,
      ),
    );
    return cells;
  }

  Future<void> _markNextDoseTaken(
    BuildContext context,
    MedicationProvider provider,
    ({Medication med, ScheduleTime s}) next,
  ) async {
    final result = await provider.toggleDoseStatus(
      next.med.id,
      next.s.id,
      true,
    );
    if (!context.mounted) return;
    if (result != DoseStatusChangeResult.updated &&
        result != DoseStatusChangeResult.alreadySet) {
      final message = switch (result) {
        DoseStatusChangeResult.expired =>
          'This medicine has expired. Do not take it.',
        DoseStatusChangeResult.recentlyTaken =>
          'This dose was marked as taken recently.',
        DoseStatusChangeResult.readOnly =>
          'A caregiver view cannot change the patient schedule.',
        _ => 'This dose could not be updated.',
      };
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    if (result == DoseStatusChangeResult.updated) {
      AccessibilityFeedback.doseCompleted();
    }
    await context.read<NotificationProvider>().dismissDoseAlarm(
      medicationId: next.med.id,
      scheduleId: next.s.id,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('${next.med.name} marked as taken'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 112),
          shape: const StadiumBorder(),
        ),
      );
  }

  // ── Standard dashboard ────────────────────────────────────────────────────

  Widget _buildStandardDashboard(
    MedicationProvider provider,
    AuthProvider authProvider,
  ) {
    final next = _findNextDose(provider);
    final cells = _buildBlocks(provider, next);

    final filtered = _selectedBlock == 'all'
        ? provider.medications
        : provider.medications
              .where((m) => m.schedule.any((s) => s.label == _selectedBlock))
              .toList();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          'MediSense',
          style: AppTheme.textStyle(fontWeight: FontWeight.w800, fontSize: 22),
        ),
        centerTitle: true,
      ),
      // The primary phone journey lives in the thumb-reachable dock. The
      // drawer is reserved for secondary destinations and legacy deep links.
      body: SafeArea(
        child: Column(
          children: [
            if (authProvider.hasPairedPatient && provider.isViewingPatient)
              _PairedPatientBanner(
                authProvider: authProvider,
                provider: provider,
              ),
            Expanded(
              child: provider.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: () => provider.loadMedications(),
                      child: ListView(
                        physics: const ClampingScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
                        children: [
                          _GreetingSection(
                            authProvider: authProvider,
                            totalDoses: provider.totalDoses,
                            totalTaken: provider.totalTaken,
                          ),
                          if (authProvider.isGuardian) ...[
                            const SizedBox(height: 16),
                            GuardianHomeCard(guardianId: authProvider.userId),
                          ],
                          if (authProvider.isPatient &&
                              authProvider.isLoggedIn) ...[
                            const SizedBox(height: 16),
                            CareReminderInbox(patientId: authProvider.userId),
                          ],
                          const SizedBox(height: 20),
                          _NextDoseCard(
                            next: next,
                            isEmpty: provider.medications.isEmpty,
                            onTake: next == null
                                ? null
                                : () => _markNextDoseTaken(
                                    context,
                                    provider,
                                    next,
                                  ),
                          ),
                          if (authProvider.isPatient &&
                              authProvider.isLoggedIn) ...[
                            const SizedBox(height: 12),
                            const PatientGuardianHomeCard(),
                          ],
                          const SizedBox(height: 14),
                          _BlisterStrip(
                            cells: cells,
                            selectedId: _selectedBlock,
                            onSelect: (id) =>
                                setState(() => _selectedBlock = id),
                          ),
                          const SizedBox(height: 14),
                          _StatsBar(
                            adherence: provider.overallAdherence,
                            missed: provider.totalMissedDoses,
                            totalDoses: provider.totalDoses,
                          ),
                          const SizedBox(height: 28),
                          _RoutineHeader(
                            selectedBlock: _selectedBlock,
                            onSeeAll: () => context.go('/schedule'),
                          ),
                          const SizedBox(height: 14),
                          if (provider.medications.isEmpty)
                            _EmptyState(onScan: () => context.go('/scan'))
                          else if (filtered.isEmpty)
                            _BlockEmptyState(
                              block: _selectedBlock,
                              onShowAll: () =>
                                  setState(() => _selectedBlock = 'all'),
                            )
                          else
                            ...filtered.map(
                              (med) => Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: MedicationCard(
                                  medication: med,
                                  filterLabel: _selectedBlock == 'all'
                                      ? null
                                      : _selectedBlock,
                                  onTap: () =>
                                      context.go('/medication/${med.id}'),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: const MediBottomNav(currentRoute: '/'),
    );
  }

  // ── Elder dashboard ───────────────────────────────────────────────────────

  Widget _buildElderDashboard(
    MedicationProvider provider,
    AuthProvider authProvider,
  ) {
    final next = _findNextDose(provider);
    final cells = _buildBlocks(provider, next);

    final filtered = _selectedBlock == 'all'
        ? provider.medications
        : provider.medications
              .where((m) => m.schedule.any((s) => s.label == _selectedBlock))
              .toList();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('MediSense')),
      body: provider.isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => provider.loadMedications(),
              child: CustomScrollView(
                physics: const ClampingScrollPhysics(),
                slivers: [
                  if (authProvider.hasPairedPatient &&
                      provider.isViewingPatient)
                    SliverToBoxAdapter(
                      child: _PairedPatientBanner(
                        authProvider: authProvider,
                        provider: provider,
                      ),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _ElderGreeting(
                            authProvider: authProvider,
                            medications: provider.medications,
                          ),
                          if (authProvider.isGuardian) ...[
                            const SizedBox(height: 16),
                            GuardianHomeCard(
                              guardianId: authProvider.userId,
                              large: true,
                            ),
                          ],
                          if (authProvider.isPatient &&
                              authProvider.isLoggedIn) ...[
                            const SizedBox(height: 16),
                            CareReminderInbox(
                              patientId: authProvider.userId,
                              large: true,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (provider.medications.isEmpty)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 28, 20, 160),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _ElderEmptyState(onScan: () => context.go('/scan')),
                            if (authProvider.isPatient &&
                                authProvider.isLoggedIn) ...[
                              const SizedBox(height: 16),
                              const PatientGuardianHomeCard(large: true),
                            ],
                          ],
                        ),
                      ),
                    )
                  else ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                        child: _ElderTakePanel(
                          next: next,
                          onYes: next == null
                              ? null
                              : () =>
                                    _markNextDoseTaken(context, provider, next),
                        ),
                      ),
                    ),
                    if (authProvider.isPatient && authProvider.isLoggedIn)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                        sliver: const SliverToBoxAdapter(
                          child: PatientGuardianHomeCard(large: true),
                        ),
                      ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 28, 20, 160),
                      sliver: SliverList(
                        delegate: SliverChildListDelegate([
                          _BlisterStrip(
                            cells: cells,
                            selectedId: _selectedBlock,
                            isElder: true,
                            onSelect: (id) =>
                                setState(() => _selectedBlock = id),
                          ),
                          const SizedBox(height: 28),
                          _RoutineHeader(
                            selectedBlock: _selectedBlock,
                            isElder: true,
                            onSeeAll: () => context.go('/schedule'),
                          ),
                          const SizedBox(height: 14),
                          if (filtered.isEmpty)
                            _BlockEmptyState(
                              block: _selectedBlock,
                              isElder: true,
                              onShowAll: () =>
                                  setState(() => _selectedBlock = 'all'),
                            )
                          else
                            ...filtered.map(
                              (med) => Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: MedicationCard(
                                  medication: med,
                                  isElder: true,
                                  filterLabel: _selectedBlock == 'all'
                                      ? null
                                      : _selectedBlock,
                                  onTap: () =>
                                      context.go('/medication/${med.id}'),
                                ),
                              ),
                            ),
                        ]),
                      ),
                    ),
                  ],
                ],
              ),
            ),
      bottomNavigationBar: ElderBottomNav(
        currentRoute: '/',
        visionLoss: context
            .read<AppStateProvider>()
            .accessibilityMode
            .isVisionLoss,
      ),
    );
  }
}

class _BlockCell {
  final String id;
  final String label;
  final int count;
  final int taken;
  final bool isNow;
  final bool hasMissed;

  const _BlockCell({
    required this.id,
    required this.label,
    required this.count,
    required this.taken,
    required this.isNow,
    required this.hasMissed,
  });

  bool get done => count > 0 && taken == count;
  bool get empty => count == 0;
  int get pending => count - taken;
}

int _timeInMinutes(TimeOfDay t) => t.hour * 60 + t.minute;

/// One hub card: a small-caps title over a white rounded-24 tappable body.
class _GreetingSection extends StatelessWidget {
  final AuthProvider authProvider;
  final int totalDoses;
  final int totalTaken;
  const _GreetingSection({
    required this.authProvider,
    required this.totalDoses,
    required this.totalTaken,
  });

  @override
  Widget build(BuildContext context) {
    final appState = context.read<AppStateProvider>();
    final name =
        resolveGreetingName([
          if (authProvider.isLoggedIn) authProvider.userName,
          appState.savedUserName,
          appState.onboardingName,
        ]) ??
        (appState.isFilipino ? 'kaibigan' : 'there');
    final summary = _summary();
    final initial = name.trim().isEmpty ? 'M' : name.trim()[0].toUpperCase();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                DateFormat('EEEE, MMMM d').format(DateTime.now()).toUpperCase(),
                style: AppTheme.microLabel(
                  color: AppTheme.secondaryTextColor(context),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '$greeting, $name',
                softWrap: true,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 3),
              Text(summary, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: (isDark ? AppTheme.darkAccentGreen : AppTheme.mint)
                .withValues(alpha: 0.16),
            border: Border.all(
              color: isDark ? AppTheme.darkSuccess : AppTheme.mint,
              width: 1.5,
            ),
          ),
          child: Center(
            child: Text(
              initial,
              style: AppTheme.textStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: isDark ? AppTheme.darkSuccess : AppTheme.mint,
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _summary() {
    if (totalDoses == 0) return 'No doses scheduled for today';
    if (totalTaken == totalDoses) return 'All $totalDoses doses taken today';
    final left = totalDoses - totalTaken;
    return '$left of $totalDoses doses left today';
  }

  static String get greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }
}

class _ElderGreeting extends StatelessWidget {
  final AuthProvider authProvider;
  final List<Medication> medications;
  const _ElderGreeting({required this.authProvider, required this.medications});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? AppTheme.elderDarkInk : AppTheme.elderInk;
    final muted = isDark ? AppTheme.elderDarkMuted : AppTheme.elderMuted;
    final appState = context.read<AppStateProvider>();
    final name =
        resolveGreetingName([
          if (authProvider.isLoggedIn) authProvider.userName,
          appState.savedUserName,
          appState.onboardingName,
        ]) ??
        (appState.isFilipino ? 'kaibigan' : 'there');
    final total = medications.fold<int>(0, (sum, m) => sum + m.schedule.length);
    final taken = medications.fold<int>(
      0,
      (sum, m) => sum + m.schedule.where((s) => s.taken).length,
    );
    final left = total - taken;
    final sentence = total == 0
        ? 'No medicines added yet.'
        : left == 0
        ? total == 1
              ? '1 dose taken today. Well done!'
              : 'All $total doses taken today. Well done!'
        : total == 1
        ? '1 dose left today.'
        : '$left of $total doses left today.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          DateFormat('EEEE, MMMM d').format(DateTime.now()),
          style: AppTheme.textStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: muted,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${_GreetingSection.greeting}, $name',
          style: AppTheme.textStyle(
            fontSize: 38,
            fontWeight: FontWeight.w800,
            color: ink,
            height: 1.05,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          sentence,
          style: AppTheme.textStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: muted,
          ),
        ),
      ],
    );
  }
}

// ── Elder take panel — WAS DUE / NEXT DOSE hero + a yes/no check-in ─────────

class _ElderTakePanel extends StatelessWidget {
  final ({Medication med, ScheduleTime s})? next;
  final Future<void> Function()? onYes;
  const _ElderTakePanel({required this.next, required this.onYes});

  @override
  Widget build(BuildContext context) {
    final next = this.next;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? AppTheme.elderDarkInk : AppTheme.elderInk;
    final muted = isDark ? AppTheme.elderDarkMuted : AppTheme.elderMuted;
    final card = isDark ? AppTheme.elderDarkCard : AppTheme.elderCard;
    final done = isDark ? AppTheme.elderDarkDone : AppTheme.elderDone;

    if (next == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
        decoration: BoxDecoration(
          color: card,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: done.withValues(alpha: 0.35)),
        ),
        child: Column(
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(color: done, shape: BoxShape.circle),
              child: const Icon(
                Icons.check_rounded,
                color: Colors.white,
                size: 52,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'You\'re done for today',
              style: AppTheme.textStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'All doses taken. Take a break.',
              textAlign: TextAlign.center,
              style: AppTheme.textStyle(
                fontSize: 21,
                fontWeight: FontWeight.w600,
                color: muted,
              ),
            ),
          ],
        ),
      );
    }

    final isOverdue =
        _timeInMinutes(next.s.time) < _timeInMinutes(TimeOfDay.now());
    final state = isDark
        ? (isOverdue ? AppTheme.elderDarkOverdue : AppTheme.elderDarkDone)
        : (isOverdue ? AppTheme.elderOverdue : AppTheme.elderDone);
    final action = isDark ? AppTheme.elderDarkAction : AppTheme.elderAction;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: state.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Text(
            isOverdue ? 'WAS DUE' : 'NEXT DOSE',
            style: AppTheme.textStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
              color: state,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            next.s.formattedTime.toUpperCase(),
            style: AppTheme.bigNumber(fontSize: 44, color: ink),
          ),
          const SizedBox(height: 8),
          Text(
            next.med.name,
            softWrap: true,
            style: AppTheme.textStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            next.med.dosage,
            style: AppTheme.textStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: muted,
            ),
          ),
          const SizedBox(height: 22),
          Container(height: 1, color: ink.withValues(alpha: 0.12)),
          const SizedBox(height: 22),
          Text(
            'Took Medicine?',
            style: AppTheme.textStyle(
              fontSize: 27,
              fontWeight: FontWeight.w800,
              color: ink,
            ),
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisSize: MainAxisSize.max,
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () async {
                      HapticFeedback.lightImpact();
                      await onYes?.call();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: action,
                      foregroundColor: isDark
                          ? AppTheme.elderDarkPaper
                          : Colors.white,
                      minimumSize: const Size(0, 56),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.max,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.check_rounded, size: 28),
                        const SizedBox(width: 4),
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'Yes',
                              style: AppTheme.textStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                color: isDark
                                    ? AppTheme.elderDarkPaper
                                    : Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => HapticFeedback.selectionClick(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: ink,
                      minimumSize: const Size(0, 56),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      side: BorderSide(
                        color: ink.withValues(alpha: 0.4),
                        width: 2,
                      ),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'No',
                        style: AppTheme.textStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: ink,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Next dose hero ──────────────────────────────────────────────────────────

class _NextDoseCard extends StatelessWidget {
  final ({Medication med, ScheduleTime s})? next;
  final bool isEmpty;
  final Future<void> Function()? onTake;

  const _NextDoseCard({required this.next, required this.isEmpty, this.onTake});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final next = this.next;
    final isEmpty = this.isEmpty;

    if (isEmpty) {
      return _FoilPanel(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'START YOUR ROUTINE',
                    style: AppTheme.microLabel(
                      color: isDark ? AppTheme.darkFoil : AppTheme.warning,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Scan a medicine label to set up your first dose.',
                    style: AppTheme.textStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: isDark
                          ? AppTheme.darkTextPrimary
                          : AppTheme.textPrimary,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            const MedicineBottleIllustration(size: 72),
          ],
        ),
      );
    }

    if (next == null) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: (isDark ? AppTheme.darkSuccess : AppTheme.success).withValues(
            alpha: 0.12,
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: (isDark ? AppTheme.darkSuccess : AppTheme.success)
                .withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: (isDark ? AppTheme.darkSuccess : AppTheme.success),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.check_rounded,
                color: isDark ? Colors.black : Colors.white,
                size: 28,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ALL DOSES TAKEN',
                    style: AppTheme.microLabel(
                      color: isDark ? AppTheme.darkSuccess : AppTheme.success,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'You are done for today. Take a break.',
                    style: AppTheme.textStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: isDark
                          ? AppTheme.darkTextPrimary
                          : AppTheme.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final isOverdue =
        _timeInMinutes(next.s.time) < _timeInMinutes(TimeOfDay.now());
    final label = isOverdue ? 'WAS DUE' : 'NEXT DOSE';
    final labelColor = isOverdue
        ? (isDark ? AppTheme.darkError : AppTheme.error)
        : (isDark ? AppTheme.darkFoil : AppTheme.foil);

    return _FoilPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: AppTheme.microLabel(
                        color: labelColor,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      next.s.formattedTime.toUpperCase(),
                      style: AppTheme.bigNumber(
                        fontSize: 34,
                        color: isDark
                            ? AppTheme.darkTextPrimary
                            : AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 7,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          next.med.name,
                          style: AppTheme.textStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: isDark
                                ? AppTheme.darkTextPrimary
                                : AppTheme.textPrimary,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: (isDark ? Colors.white : AppTheme.ink)
                                .withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${next.med.dosage} ${next.med.form}',
                            style: AppTheme.textStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: isDark
                                  ? AppTheme.darkTextSecondary
                                  : AppTheme.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _PillIcon(
                color: isOverdue ? AppTheme.error : AppTheme.foil,
                size: 54,
                label: '1 tablet',
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 56,
            child: FilledButton.icon(
              onPressed: onTake,
              icon: const Icon(Icons.check_circle_outline_rounded),
              label: Text(
                'Take Now',
                style: TextStyle(
                  height: 1.2,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: isDark ? AppTheme.darkSuccess : AppTheme.mint,
                foregroundColor: isDark ? Colors.black : Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                minimumSize: const Size.fromHeight(52),
                tapTargetSize: MaterialTapTargetSize.padded,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FoilPanel extends StatelessWidget {
  final Widget child;
  const _FoilPanel({required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foil = isDark ? AppTheme.darkFoil : AppTheme.foil;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: foil.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: foil.withValues(alpha: 0.4)),
      ),
      child: child,
    );
  }
}

class _PillIcon extends StatelessWidget {
  final Color color;
  final double size;
  final String? label;
  const _PillIcon({required this.color, this.size = 52, this.label});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size * 0.62,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(size),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.35),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: Container(
              width: size * 0.42,
              height: 2,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
        if (label != null) ...[
          const SizedBox(height: 6),
          Text(
            label!,
            style: AppTheme.microLabel(
              fontSize: 9.5,
              letterSpacing: 0.6,
              color: isDark
                  ? AppTheme.darkTextSecondary
                  : AppTheme.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

// ── Blister strip ───────────────────────────────────────────────────────────

class _BlisterStrip extends StatelessWidget {
  final List<_BlockCell> cells;
  final String selectedId;
  final ValueChanged<String> onSelect;
  final bool isElder;

  const _BlisterStrip({
    required this.cells,
    required this.selectedId,
    required this.onSelect,
    this.isElder = false,
  });

  String _shortLabel(String id) {
    switch (id) {
      case 'all':
        return 'All';
      case 'Morning':
        return 'Morn';
      case 'Afternoon':
        return 'Noon';
      case 'Evening':
        return 'Eve';
      case 'Night':
        return 'Night';
      default:
        return id;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (!isElder) {
      return SizedBox(
        height: 50,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: cells.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final cell = cells[index];
            return _StandardFilterPill(
              label: _shortLabel(cell.id),
              count: cell.count,
              selected: cell.id == selectedId,
              onTap: () => onSelect(cell.id),
            );
          },
        ),
      );
    }
    final all = cells.firstWhere((cell) => cell.id == 'all');
    final morning = cells.firstWhere((cell) => cell.id == 'Morning');
    final afternoon = cells.firstWhere((cell) => cell.id == 'Afternoon');
    final evening = cells.firstWhere((cell) => cell.id == 'Evening');
    final night = cells.firstWhere((cell) => cell.id == 'Night');
    final nightCell = _BlockCell(
      id: 'Night',
      label: 'Night',
      count: evening.count + night.count,
      taken: evening.taken + night.taken,
      isNow: evening.isNow || night.isNow,
      hasMissed: evening.hasMissed || night.hasMissed,
    );
    final displayCells = [all, morning, afternoon, nightCell];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        height: 56,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkSegmentTrack : AppTheme.muted,
          borderRadius: BorderRadius.circular(14),
          border: isDark
              ? Border.all(color: Colors.white.withValues(alpha: 0.08))
              : null,
        ),
        child: Row(
          children: [
            for (final cell in displayCells)
              Expanded(
                child: _ElderFilterSegment(
                  cell: cell,
                  isSelected:
                      selectedId == cell.id ||
                      (cell.id == 'Night' && selectedId == 'Evening'),
                  onTap: () {
                    final nextId = cell.id;
                    if (selectedId != nextId) {
                      HapticFeedback.selectionClick();
                    }
                    onSelect(nextId);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StandardFilterPill extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _StandardFilterPill({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppTheme.darkSuccess : AppTheme.mint;
    final ink = isDark ? AppTheme.darkTextPrimary : AppTheme.textPrimary;
    return Semantics(
      button: true,
      selected: selected,
      label: '$label, $count doses${selected ? ', selected' : ''}',
      child: Material(
        color: selected
            ? accent
            : (isDark ? AppTheme.darkCardSurface : Colors.white),
        borderRadius: BorderRadius.circular(25),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(25),
          child: Container(
            constraints: const BoxConstraints(minWidth: 64),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(25),
              border: Border.all(
                color: selected ? accent : AppTheme.borderColor(context),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: AppTheme.textStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: selected
                        ? (isDark ? Colors.black : Colors.white)
                        : ink,
                  ),
                ),
                const SizedBox(width: 7),
                Container(
                  constraints: const BoxConstraints(minWidth: 20),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? Colors.white.withValues(alpha: 0.2)
                        : accent.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$count',
                    textAlign: TextAlign.center,
                    style: AppTheme.textStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: selected
                          ? (isDark ? Colors.black : Colors.white)
                          : accent,
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

class _ElderFilterSegment extends StatelessWidget {
  final _BlockCell cell;
  final bool isSelected;
  final VoidCallback onTap;

  const _ElderFilterSegment({
    required this.cell,
    required this.isSelected,
    required this.onTap,
  });

  IconData get _icon => switch (cell.id) {
    'all' => Icons.calendar_month_rounded,
    'Morning' => Icons.wb_sunny_rounded,
    'Afternoon' => Icons.wb_sunny_outlined,
    _ => Icons.nightlight_round,
  };

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foreground = isSelected
        ? (isDark ? AppTheme.darkSuccess : AppTheme.primaryDark)
        : (isDark ? AppTheme.darkTextSecondary : AppTheme.textPrimary);
    final countBackground = isSelected
        ? foreground
        : (isDark ? AppTheme.darkAccent : AppTheme.accent);
    final badgeForeground = isDark
        ? AppTheme.darkTextPrimary
        : AppTheme.inkText;
    return Semantics(
      button: true,
      selected: isSelected,
      label: '${cell.label}, ${cell.count} doses',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(11),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            margin: const EdgeInsets.all(1),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            decoration: BoxDecoration(
              color: isSelected
                  ? (isDark ? AppTheme.darkCardSurface : Colors.white)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(11),
              boxShadow: isSelected
                  ? const [
                      BoxShadow(
                        color: Color(0x1F000000),
                        blurRadius: 8,
                        offset: Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_icon, size: 19, color: foreground),
                    const SizedBox(height: 3),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        cell.label,
                        maxLines: 1,
                        softWrap: false,
                        style: AppTheme.textStyle(
                          color: foreground,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                Positioned(
                  top: 2,
                  right: 8,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 16),
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color: countBackground,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${cell.count}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: badgeForeground,
                        fontSize: 8,
                        fontWeight: FontWeight.w800,
                        height: 1.25,
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

class _StatsBar extends StatelessWidget {
  final double adherence;
  final int missed;
  final int totalDoses;
  const _StatsBar({
    required this.adherence,
    required this.missed,
    required this.totalDoses,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCardSurface : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.borderColor(context)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            height: 42,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CircularProgressIndicator(
                  value: adherence.clamp(0.0, 1.0),
                  strokeWidth: 5,
                  color: isDark ? AppTheme.darkSuccess : AppTheme.mint,
                  backgroundColor: (isDark ? Colors.white : AppTheme.ink)
                      .withValues(alpha: 0.1),
                ),
                Center(
                  child: Text(
                    '${(adherence * 100).round()}%',
                    style: AppTheme.textStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.primaryTextColor(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Today’s progress',
              style: AppTheme.textStyle(
                fontWeight: FontWeight.w800,
                color: AppTheme.primaryTextColor(context),
              ),
            ),
          ),
          _Stat(
            label: 'MISSED',
            value: '$missed',
            color: isDark ? AppTheme.darkError : AppTheme.error,
          ),
          const SizedBox(width: 18),
          _Stat(
            label: 'DOSES',
            value: '$totalDoses',
            color: isDark ? AppTheme.darkAccentGreen : AppTheme.mint,
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Stat({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: AppTheme.microLabel(
            fontSize: 9.5,
            color: Theme.of(context).brightness == Brightness.dark
                ? AppTheme.darkTextSecondary
                : AppTheme.mutedText,
          ),
        ),
        const SizedBox(height: 4),
        Text(value, style: AppTheme.bigNumber(fontSize: 20, color: color)),
      ],
    );
  }
}

// ── Elder stats ─────────────────────────────────────────────────────────────

class _RoutineHeader extends StatelessWidget {
  final String selectedBlock;
  final bool isElder;
  final VoidCallback onSeeAll;
  const _RoutineHeader({
    required this.selectedBlock,
    required this.onSeeAll,
    this.isElder = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final title = selectedBlock == 'all'
        ? 'Today\'s medicines'
        : '$selectedBlock doses';
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title.toUpperCase(),
          style: AppTheme.microLabel(
            fontSize: isElder ? 15 : 12,
            letterSpacing: isElder ? 1 : 1.1,
            fontWeight: FontWeight.w600,
            color: isDark ? AppTheme.darkTextSecondary : AppTheme.textPrimary,
          ),
        ),
        TextButton(
          onPressed: onSeeAll,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(48, 40),
          ),
          child: Text(
            'See all',
            style: AppTheme.textStyle(
              fontWeight: FontWeight.w800,
              fontSize: isElder ? 20 : 14,
              color: isDark ? AppTheme.darkAccentGreen : AppTheme.mint,
            ),
          ),
        ),
      ],
    );
  }
}

class _BlockEmptyState extends StatelessWidget {
  final String block;
  final bool isElder;
  final VoidCallback onShowAll;
  const _BlockEmptyState({
    required this.block,
    required this.onShowAll,
    this.isElder = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? AppTheme.darkCardSurface : AppTheme.card;
    final iconColor = isDark ? AppTheme.darkTextPrimary : AppTheme.ink;
    final messageColor = isDark ? AppTheme.darkTextPrimary : AppTheme.inkText;
    if (isElder) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.borderColor(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : AppTheme.muted,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.schedule_rounded, size: 38, color: iconColor),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Nothing due in the ${block.toLowerCase()}',
              style: AppTheme.textStyle(
                fontSize: 24,
                height: 1.25,
                fontWeight: FontWeight.w700,
                color: messageColor,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 56,
              child: OutlinedButton.icon(
                onPressed: onShowAll,
                icon: const Icon(Icons.list_alt_rounded),
                label: Text(
                  'Show all medicines',
                  style: AppTheme.textStyle(
                    fontWeight: FontWeight.w800,
                    color: isDark ? AppTheme.darkAccentGreen : AppTheme.mint,
                    fontSize: 19,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: EdgeInsets.all(isElder ? 28 : 20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.borderColor(context)),
      ),
      child: Row(
        children: [
          Container(
            width: isElder ? 56 : 48,
            height: isElder ? 56 : 48,
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : AppTheme.muted,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.schedule_rounded,
              size: isElder ? 40 : 28,
              color: iconColor,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'Nothing due in the ${block.toLowerCase()}',
              style: AppTheme.textStyle(
                fontSize: isElder ? 22 : 16,
                fontWeight: FontWeight.w700,
                color: messageColor,
              ),
            ),
          ),
          TextButton(
            onPressed: onShowAll,
            child: Text(
              'Show all',
              style: AppTheme.textStyle(
                fontWeight: FontWeight.w800,
                color: isDark ? AppTheme.darkAccentGreen : AppTheme.mint,
                fontSize: isElder ? 18 : 16,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onScan;
  const _EmptyState({required this.onScan});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCardSurface : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.borderColor(context)),
      ),
      child: Column(
        children: [
          const MedicineBottleIllustration(size: 82),
          const SizedBox(height: 18),
          Text(
            'No medications today',
            style: AppTheme.textStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Scan your first medication to start your routine.',
            textAlign: TextAlign.center,
            style: AppTheme.textStyle(
              fontSize: 13,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton.icon(
              onPressed: onScan,
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
              label: const Text(
                '+ Scan Medicine',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
              ),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF5D7052),
                foregroundColor: const Color(0xFFF3F4F1),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ElderEmptyState extends StatelessWidget {
  final VoidCallback onScan;

  const _ElderEmptyState({required this.onScan});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final card = isDark ? AppTheme.elderDarkCard : AppTheme.elderCard;
    final ink = isDark ? AppTheme.elderDarkInk : AppTheme.elderInk;
    final muted = isDark ? AppTheme.elderDarkMuted : AppTheme.elderMuted;

    return Container(
      padding: const EdgeInsets.all(36),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppTheme.elderAction.withValues(alpha: 0.35)),
      ),
      child: Column(
        children: [
          const MedicineBottleIllustration(size: 104),
          const SizedBox(height: 20),
          Text(
            'No medicines yet',
            textAlign: TextAlign.center,
            style: AppTheme.textStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: ink,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Scan a medicine label to set up your first dose.',
            textAlign: TextAlign.center,
            style: AppTheme.textStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: muted,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 26),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton.icon(
              onPressed: onScan,
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 24),
              label: Text(
                '+ Scan Medicine',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: AppTheme.textStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFFF3F4F1),
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF5D7052),
                foregroundColor: const Color(0xFFF3F4F1),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PairedPatientBanner extends StatelessWidget {
  final AuthProvider authProvider;
  final MedicationProvider provider;
  const _PairedPatientBanner({
    required this.authProvider,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: AppTheme.accentGreen.withValues(alpha: 20 / 255),
      child: Row(
        children: [
          const Icon(
            Icons.visibility_rounded,
            color: AppTheme.accentGreen,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Viewing ${authProvider.pairedPatientName}\'s medications',
              style: AppTheme.textStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.accentGreen,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              authProvider.clearPairedPatient();
              provider.viewOwnMedications();
            },
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Back to mine', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

// ── Elder bottom nav ────────────────────────────────────────────────────────
