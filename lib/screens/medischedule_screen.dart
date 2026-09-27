import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';
import '../providers/medication_provider.dart';
import '../models/medication.dart';
import '../models/scheduled_dose.dart';
import '../widgets/pill_tile.dart';
import '../providers/auth_provider.dart';
import '../providers/tts_provider.dart';
import '../providers/voice_navigation_provider.dart';
import '../providers/app_state_provider.dart';
import '../models/accessibility_mode.dart';
import '../widgets/elder_bottom_nav.dart';
import '../widgets/add_medication_modal.dart';
import '../widgets/medi_bottom_nav.dart';
import '../widgets/medicine_bottle_illustration.dart';
import '../services/accessibility_feedback.dart';
import '../services/medication_semantics.dart';
import '../services/greeting_name.dart';

typedef _BlockInfo = ({IconData icon, String label, List<ScheduledDose> doses});

class MediScheduleScreen extends StatefulWidget {
  const MediScheduleScreen({super.key});

  @override
  State<MediScheduleScreen> createState() => _MediScheduleScreenState();
}

class _MediScheduleScreenState extends State<MediScheduleScreen>
    with AutomaticKeepAliveClientMixin {
  bool _hasGreeted = false;

  /// Toggles a dose's taken state with the duplicate-dose guard when marking
  /// taken shortly after it was already marked.
  Future<void> _toggleDose(
    BuildContext context,
    MedicationProvider provider,
    Medication med,
    ScheduleTime sched,
  ) async {
    final result = await provider.toggleDoseStatus(
      med.id,
      sched.id,
      !sched.taken,
    );
    if (!context.mounted ||
        result == DoseStatusChangeResult.updated ||
        result == DoseStatusChangeResult.alreadySet) {
      return;
    }
    final message = switch (result) {
      DoseStatusChangeResult.expired =>
        'This medicine has expired. Do not take it.',
      DoseStatusChangeResult.recentlyTaken =>
        'This dose was marked as taken recently and cannot be recorded again.',
      DoseStatusChangeResult.readOnly =>
        'A caregiver view cannot change the patient schedule.',
      _ => 'This dose could not be updated.',
    };
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _scheduleSummary(
    List<_BlockInfo> blocks,
    List<Medication> prnMedications,
  ) {
    final parts = <String>[];
    for (final b in blocks) {
      if (b.doses.isEmpty) continue;
      final names = b.doses
          .map(
            (dose) =>
                '${dose.medication.name} ${dose.medication.dosage} at ${dose.schedule.formattedTime}',
          )
          .join(', ');
      parts.add('${b.label}: $names');
    }
    if (prnMedications.isNotEmpty) {
      parts.add(
        'As needed: ${prnMedications.map((medication) => medication.name).join(', ')}',
      );
    }
    if (parts.isEmpty) return 'Your medication schedule is empty.';
    return 'Your medication schedule. ${parts.join('. ')}';
  }

  String _scheduleSummaryFil(
    List<_BlockInfo> blocks,
    List<Medication> prnMedications,
  ) {
    final parts = <String>[];
    for (final b in blocks) {
      if (b.doses.isEmpty) continue;
      final names = b.doses
          .map(
            (dose) =>
                '${dose.medication.name} ${dose.medication.dosage} nang ${dose.schedule.formattedTime}',
          )
          .join(', ');
      parts.add('${b.label}: $names');
    }
    if (prnMedications.isNotEmpty) {
      parts.add(
        'Kung kinakailangan: ${prnMedications.map((medication) => medication.name).join(', ')}',
      );
    }
    if (parts.isEmpty) return 'Wala pang nakatakdang gamot.';
    return 'Ang iyong iskedyul ng mga gamot. ${parts.join('. ')}';
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_hasGreeted) {
      final appState = context.read<AppStateProvider>();
      final tts = context.read<TtsProvider>();
      if (appState.accessibilityMode.isVisionLoss &&
          appState.ttsVerbosity != TtsVerbosity.essential) {
        final auth = context.watch<AuthProvider>();
        if (appState.savedUserId != null && !auth.isLoggedIn) return;
        final name = resolveGreetingName([
          if (auth.isLoggedIn) auth.userName,
          appState.savedUserName,
          appState.onboardingName,
        ]);
        if (appState.ttsVerbosity == TtsVerbosity.detailed) {
          context.read<VoiceNavigationProvider>().readCurrentScreen();
        } else {
          tts.speak(
            name == null
                ? 'Here is your medication schedule.'
                : 'Hello $name, here is your medication schedule.',
            name == null
                ? 'Narito ang iskedyul ng iyong mga gamot.'
                : 'Kumusta, $name. Narito ang iskedyul ng iyong mga gamot.',
          );
        }
      }
      _hasGreeted = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final provider = context.watch<MedicationProvider>();
    final mode = context.watch<AppStateProvider>().accessibilityMode;
    final isElder = mode.isElder || mode.isVisionLoss;

    final blocks = <_BlockInfo>[
      (
        icon: Icons.wb_sunny_rounded,
        label: 'Morning',
        doses: scheduledDosesForBlock(provider.medications, 'Morning'),
      ),
      (
        icon: Icons.wb_cloudy_rounded,
        label: 'Afternoon',
        doses: scheduledDosesForBlock(provider.medications, 'Afternoon'),
      ),
      (
        icon: Icons.nights_stay_rounded,
        label: 'Evening',
        doses: scheduledDosesForBlock(provider.medications, 'Evening'),
      ),
      (
        icon: Icons.bedtime_rounded,
        label: 'Night',
        doses: scheduledDosesForBlock(provider.medications, 'Night'),
      ),
    ];

    final prnMedications = provider.medications
        .where((medication) => medication.frequency == 'As needed')
        .toList(growable: false);
    final hasAny =
        blocks.any((b) => b.doses.isNotEmpty) || prnMedications.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('MediSense'),
        actions: [
          IconButton(
            tooltip: 'Read today’s schedule aloud',
            icon: const Icon(Icons.volume_up_rounded),
            onPressed: () => context.read<TtsProvider>().speak(
              _scheduleSummary(blocks, prnMedications),
              _scheduleSummaryFil(blocks, prnMedications),
            ),
          ),
          _buildAddAction(context),
          const SizedBox(width: 8),
        ],
      ),
      // Keep the schedule one tap away in the shared bottom dock.
      body: Column(
        children: [
          Expanded(
            child: !hasAny
                ? _ScheduleEmptyState(
                    isElder: isElder,
                    onAddManually: () => _showAddMedicationDialog(context),
                  )
                : ListView(
                    padding: EdgeInsets.only(top: 16, bottom: 110),
                    children: [
                      if (prnMedications.isNotEmpty) ...[
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: isElder ? 16 : 0,
                          ),
                          child: _TimeBlockHeader(
                            icon: Icons.medication_outlined,
                            label: 'As needed',
                            count: prnMedications.length,
                            isNow: false,
                            isElder: isElder,
                          ),
                        ),
                        for (final medication in prnMedications)
                          Card(
                            margin: EdgeInsets.fromLTRB(
                              isElder ? 16 : 0,
                              4,
                              isElder ? 16 : 0,
                              8,
                            ),
                            child: ListTile(
                              minVerticalPadding: isElder ? 16 : 12,
                              leading: const Icon(Icons.medication_outlined),
                              title: Text(
                                medication.name,
                                style: TextStyle(
                                  fontSize: isElder ? 20 : 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              subtitle: Text(
                                [medication.dosage, medication.form]
                                    .where((part) => part.trim().isNotEmpty)
                                    .join(' · '),
                                style: TextStyle(fontSize: isElder ? 16 : 14),
                              ),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () =>
                                  context.go('/medication/${medication.id}'),
                            ),
                          ),
                        const SizedBox(height: 16),
                      ],
                      for (final block in blocks)
                        if (block.doses.isNotEmpty) ...[
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              isElder ? 16 : 0,
                              isElder ? 8 : 0,
                              isElder ? 16 : 0,
                              isElder ? 8 : 0,
                            ),
                            child: Container(
                              padding: EdgeInsets.only(
                                bottom: isElder ? 12 : 0,
                              ),
                              decoration: isElder
                                  ? BoxDecoration(
                                      color:
                                          Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? AppTheme.elderDarkCard.withValues(
                                              alpha: 0.72,
                                            )
                                          : Colors.white.withValues(
                                              alpha: 0.62,
                                            ),
                                      borderRadius: BorderRadius.circular(
                                        AppTheme.cardRadius,
                                      ),
                                      border: Border.all(
                                        color: AppTheme.borderColor(
                                          context,
                                        ).withValues(alpha: 0.8),
                                      ),
                                    )
                                  : null,
                              child: Column(
                                children: [
                                  _TimeBlockHeader(
                                    icon: block.icon,
                                    label: block.label,
                                    count: block.doses.length,
                                    isNow: block.label == _currentBlock,
                                    isElder: isElder,
                                  ),
                                  ...block.doses.map(
                                    (dose) => _ScheduleTile(
                                      medication: dose.medication,
                                      schedule: dose.schedule,
                                      isElder: isElder,
                                      grouped: isElder,
                                      onTap: () => context.go(
                                        '/medication/${dose.medication.id}',
                                      ),
                                      onToggle: (_) {
                                        _toggleDose(
                                          context,
                                          provider,
                                          dose.medication,
                                          dose.schedule,
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                    ],
                  ),
          ),
        ],
      ),
      floatingActionButton: null,
      bottomNavigationBar: isElder
          ? ElderBottomNav(
              currentRoute: '/schedule',
              visionLoss: mode.isVisionLoss,
            )
          : const MediBottomNav(currentRoute: '/schedule'),
    );
  }

  Widget _buildAddAction(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Add medication manually',
      hint: 'Type in medicine details without using the camera',
      child: IconButton(
        onPressed: () => _showAddMedicationDialog(context),
        tooltip: 'Add medication manually',
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        style: IconButton.styleFrom(
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? AppTheme.darkCardSurface
              : AppTheme.muted,
          foregroundColor: Theme.of(context).brightness == Brightness.dark
              ? AppTheme.darkTextPrimary
              : AppTheme.primaryDark,
          side: BorderSide(
            color: Theme.of(context).brightness == Brightness.dark
                ? AppTheme.darkBorder
                : AppTheme.timber,
          ),
          shape: const CircleBorder(),
        ),
        icon: const Icon(Icons.add_rounded, size: 28),
      ),
    );
  }

  void _showAddMedicationDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const AddMedicationModal(),
    );
  }
}

/// The time block that is happening right now, matching the label logic used
/// when a schedule is created.
String get _currentBlock => ScheduleTime.labelFor(DateTime.now().hour);

class _ScheduleEmptyState extends StatelessWidget {
  final bool isElder;
  final VoidCallback onAddManually;

  const _ScheduleEmptyState({
    required this.isElder,
    required this.onAddManually,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final card = isDark ? AppTheme.elderDarkCard : AppTheme.elderCard;
    final ink = isDark ? AppTheme.elderDarkInk : AppTheme.elderInk;
    final muted = isDark ? AppTheme.elderDarkMuted : AppTheme.elderMuted;
    final action = isElder
        ? (isDark ? AppTheme.elderDarkInk : AppTheme.elderInk)
        : (isDark ? AppTheme.darkAccentGreen : AppTheme.ink);
    final actionText = isElder
        ? (isDark ? AppTheme.elderDarkPaper : Colors.white)
        : (isDark
              ? AppTheme.darkPrimaryForeground
              : AppTheme.primaryForeground);

    final body = Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: EdgeInsets.all(isElder ? 36 : 24),
      decoration: BoxDecoration(
        color: isElder
            ? card
            : (isDark ? AppTheme.darkCardSurface : Colors.white),
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        border: Border.all(color: AppTheme.borderColor(context)),
      ),
      child: Column(
        children: [
          MedicineBottleIllustration(size: isElder ? 104 : 82),
          SizedBox(height: isElder ? 20 : 16),
          Text(
            'No medications scheduled',
            textAlign: TextAlign.center,
            style: AppTheme.textStyle(
              fontSize: isElder ? 26 : 20,
              fontWeight: FontWeight.w800,
              color: ink,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Add your first dose to see a day\'s plan here.',
            textAlign: TextAlign.center,
            style: AppTheme.textStyle(
              fontSize: isElder ? 20 : 14,
              fontWeight: isElder ? FontWeight.w600 : FontWeight.w500,
              color: muted,
            ),
          ),
          SizedBox(height: isElder ? 26 : 20),
          Semantics(
            button: true,
            label: 'Scan medicine',
            hint: 'Scan the medicine label with the camera',
            child: SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton.icon(
                onPressed: () => context.go('/scan'),
                icon: Icon(Icons.qr_code_scanner_rounded, size: 24),
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '+ Scan Medicine',
                    maxLines: 1,
                    softWrap: false,
                    style: isElder
                        ? AppTheme.textStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: actionText,
                          )
                        : null,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: action,
                  foregroundColor: actionText,
                  minimumSize: const Size.fromHeight(56),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Semantics(
            button: true,
            label: 'Add medication manually',
            hint: 'Type in medicine details manually without using the camera',
            child: SizedBox(
              width: double.infinity,
              height: 56,
              child: OutlinedButton.icon(
                onPressed: onAddManually,
                icon: const Icon(Icons.edit_note_rounded, size: 24),
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '+ Add Manually',
                    maxLines: 1,
                    softWrap: false,
                    style: isElder
                        ? AppTheme.textStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: isDark
                                ? AppTheme.elderDarkInk
                                : AppTheme.elderAction,
                          )
                        : null,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: isElder
                      ? (isDark ? AppTheme.elderDarkInk : AppTheme.elderAction)
                      : null,
                  backgroundColor: isElder
                      ? (isDark ? AppTheme.elderDarkCard : AppTheme.muted)
                      : null,
                  side: BorderSide(
                    color: isElder
                        ? (isDark
                              ? AppTheme.elderDarkAction
                              : AppTheme.elderAction)
                        : AppTheme.borderColor(context),
                    width: 1.5,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 110),
        child: body,
      ),
    );
  }
}

class _TimeBlockHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  final bool isNow;
  final bool isElder;

  const _TimeBlockHeader({
    required this.icon,
    required this.label,
    required this.count,
    required this.isNow,
    this.isElder = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final now = isElder
        ? (isDark ? AppTheme.elderDarkAction : AppTheme.elderAction)
        : (isDark ? AppTheme.darkFoil : AppTheme.foil);
    final ink = isDark ? AppTheme.darkTextPrimary : AppTheme.elderInk;
    final accent = isDark ? AppTheme.darkAccentGreen : AppTheme.ink;
    final onNow = isDark ? AppTheme.elderDarkPaper : Colors.white;
    final nowChipBackground = isDark ? AppTheme.elderDarkCard : now;
    final nowChipBorder = isDark
        ? Border.all(color: AppTheme.darkSuccess.withValues(alpha: 0.45))
        : null;
    final countBackground = isDark
        ? AppTheme.elderDarkCard.withValues(alpha: 0.9)
        : accent.withValues(alpha: 0.08);
    final countBorder = isDark
        ? Border.all(color: Colors.white.withValues(alpha: 0.18), width: 1)
        : Border.all(color: accent.withValues(alpha: 0.12));

    return Padding(
      padding: EdgeInsets.fromLTRB(20, isElder ? 28 : 24, 20, 10),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(isElder ? 12 : 8),
            decoration: BoxDecoration(
              color: (isNow ? now : accent).withValues(
                alpha: isNow ? 0.16 : 0.12,
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              icon,
              color: isNow ? now : accent,
              size: isElder ? 32 : 24,
            ),
          ),
          const SizedBox(width: 12),
          if (isElder)
            Text(
              label,
              textAlign: TextAlign.center,
              style: AppTheme.textStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: ink,
              ),
            )
          else
            Text(
              label.toUpperCase(),
              style: AppTheme.microLabel(
                fontSize: 13,
                letterSpacing: 1,
                color: ink,
              ),
            ),
          const SizedBox(width: 8),
          if (isNow)
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: isElder ? 12 : 8,
                vertical: isElder ? 4 : 2,
              ),
              decoration: BoxDecoration(
                color: nowChipBackground,
                borderRadius: BorderRadius.circular(10),
                border: nowChipBorder,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isDark) ...[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: AppTheme.darkSuccess,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    isDark ? 'Current' : (isElder ? 'Now' : 'NOW'),
                    style: isElder
                        ? AppTheme.textStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: isDark ? AppTheme.darkTextPrimary : onNow,
                          )
                        : AppTheme.microLabel(
                            fontSize: 9,
                            letterSpacing: 0.8,
                            color: isDark
                                ? AppTheme.darkTextPrimary
                                : AppTheme.inkText,
                          ),
                  ),
                ],
              ),
            ),
          const Spacer(),
          Container(
            constraints: BoxConstraints(minWidth: isElder ? 44 : 28),
            padding: EdgeInsets.symmetric(
              horizontal: isElder ? 12 : 8,
              vertical: isElder ? 4 : 2,
            ),
            decoration: BoxDecoration(
              color: countBackground,
              borderRadius: BorderRadius.circular(14),
              border: countBorder,
            ),
            child: Text(
              '$count',
              textAlign: TextAlign.center,
              style: AppTheme.tabular(
                fontSize: isElder ? 24 : 16,
                fontWeight: FontWeight.w800,
                color: isDark ? ink : accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScheduleTile extends StatelessWidget {
  final Medication medication;
  final ScheduleTime schedule;
  final bool isElder;
  final bool grouped;
  final VoidCallback onTap;
  final void Function(String scheduleId) onToggle;

  const _ScheduleTile({
    required this.medication,
    required this.schedule,
    this.isElder = false,
    this.grouped = false,
    required this.onTap,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final blockSchedules = [schedule];
    final done = isElder
        ? (isDark ? AppTheme.elderDarkDone : AppTheme.elderDone)
        : (isDark ? AppTheme.darkSuccess : AppTheme.success);
    final card = isElder
        ? (isDark ? AppTheme.elderDarkCard : AppTheme.elderCard)
        : (isDark ? AppTheme.darkCardSurface : Colors.white);
    final ink = isElder
        ? (isDark ? AppTheme.elderDarkInk : AppTheme.elderInk)
        : AppTheme.primaryTextColor(context);
    final muted = isElder
        ? (isDark ? AppTheme.elderDarkMuted : AppTheme.elderMuted)
        : AppTheme.secondaryTextColor(context);

    final pending = blockSchedules.where((s) => !s.taken).toList();
    return Semantics(
      container: true,
      button: true,
      label: medicationSemanticsLabel(medication, scheduleId: schedule.id),
      hint:
          'Double-tap to view details. Swipe right to mark the next dose as taken.',
      customSemanticsActions: pending.isEmpty
          ? null
          : {
              CustomSemanticsAction(label: 'Mark as taken'): () {
                AccessibilityFeedback.doseCompleted();
                onToggle(pending.first.id);
              },
            },
      child: ExcludeSemantics(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: grouped ? 12 : 16,
            vertical: 4,
          ),
          child: Material(
            color: card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.cardRadius),
              side: BorderSide(
                color: AppTheme.borderColor(context),
                width: isElder ? 2 : 1,
              ),
            ),
            child: InkWell(
              onTap: () {
                AccessibilityFeedback.selection();
                onTap();
              },
              borderRadius: BorderRadius.circular(AppTheme.cardRadius),
              child: Padding(
                padding: EdgeInsets.all(isElder ? 20 : 16),
                child: isElder
                    ? _ElderScheduleTileContent(
                        medication: medication,
                        blockSchedules: blockSchedules,
                        done: done,
                        ink: ink,
                        muted: muted,
                        isDark: isDark,
                        onToggle: onToggle,
                      )
                    : _StandardScheduleTileContent(
                        medication: medication,
                        blockSchedules: blockSchedules,
                        done: done,
                        ink: ink,
                        muted: muted,
                        isDark: isDark,
                        onToggle: onToggle,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StandardScheduleTileContent extends StatelessWidget {
  final Medication medication;
  final List<ScheduleTime> blockSchedules;
  final Color done;
  final Color ink;
  final Color muted;
  final bool isDark;
  final void Function(String scheduleId) onToggle;

  const _StandardScheduleTileContent({
    required this.medication,
    required this.blockSchedules,
    required this.done,
    required this.ink,
    required this.muted,
    required this.isDark,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PillTile(color: medication.color, form: medication.form),
            const SizedBox(width: 14),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  medication.name,
                  maxLines: 1,
                  softWrap: false,
                  style: AppTheme.textStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: ink,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded, color: muted, size: 24),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${medication.dosage} ${medication.form}',
                    softWrap: true,
                    style: AppTheme.textStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: muted,
                    ),
                  ),
                  if (blockSchedules.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: blockSchedules
                          .map(
                            (s) => Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: ink.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                s.formattedTime,
                                style: AppTheme.textStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: ink,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ],
                  const SizedBox(height: 8),
                  _ExpiryNotice(
                    medication: medication,
                    muted: muted,
                    isElder: false,
                  ),
                ],
              ),
            ),
            if (blockSchedules.isNotEmpty) ...[
              const SizedBox(width: 12),
              Flexible(
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: blockSchedules
                      .map(
                        (s) => _DoseStatusButton(
                          taken: s.taken,
                          color: done,
                          foreground: ink,
                          isDark: isDark,
                          isElder: false,
                          onTap: () => onToggle(s.id),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _ElderScheduleTileContent extends StatelessWidget {
  final Medication medication;
  final List<ScheduleTime> blockSchedules;
  final Color done;
  final Color ink;
  final Color muted;
  final bool isDark;
  final void Function(String scheduleId) onToggle;

  const _ElderScheduleTileContent({
    required this.medication,
    required this.blockSchedules,
    required this.done,
    required this.ink,
    required this.muted,
    required this.isDark,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PillTile(
              color: medication.color,
              form: medication.form,
              isElder: true,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      medication.name,
                      maxLines: 1,
                      softWrap: false,
                      style: AppTheme.textStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: ink,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${medication.dosage} ${medication.form}',
                    maxLines: 2,
                    softWrap: true,
                    style: AppTheme.textStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: muted,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: blockSchedules
                        .map(
                          (s) => Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: ink.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              s.formattedTime,
                              style: AppTheme.textStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: ink,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 8),
                  _ExpiryNotice(
                    medication: medication,
                    muted: muted,
                    isElder: true,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded, color: muted, size: 30),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: blockSchedules
                .map(
                  (s) => _DoseStatusButton(
                    taken: s.taken,
                    color: done,
                    foreground: ink,
                    isDark: isDark,
                    isElder: true,
                    onTap: () => onToggle(s.id),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }
}

class _ExpiryNotice extends StatelessWidget {
  const _ExpiryNotice({
    required this.medication,
    required this.muted,
    required this.isElder,
  });

  final Medication medication;
  final Color muted;
  final bool isElder;

  @override
  Widget build(BuildContext context) {
    final expirationDate = medication.expirationDate;
    if (expirationDate == null) return const SizedBox.shrink();

    final expiring = medication.isExpiringSoon;
    final expired = medication.isExpired;
    final daysUntilExpiry = medication.daysUntilExpiry!;
    final color = expired
        ? AppTheme.error
        : expiring
        ? const Color(0xFFB26A00)
        : muted;
    final date = DateFormat('MMM d, y').format(expirationDate);
    final label = expired
        ? 'Expired on $date'
        : expiring
        ? daysUntilExpiry == 0
              ? 'Expires today · $date'
              : daysUntilExpiry == 1
              ? 'Expires tomorrow · $date'
              : 'Expires in $daysUntilExpiry days · $date'
        : 'Expires $date';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          expired || expiring
              ? Icons.warning_amber_rounded
              : Icons.calendar_today_rounded,
          size: isElder ? 21 : 16,
          color: color,
        ),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            label,
            style: AppTheme.textStyle(
              fontSize: isElder ? 16 : 12,
              fontWeight: expired || expiring
                  ? FontWeight.w800
                  : FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

class _DoseStatusButton extends StatelessWidget {
  final bool taken;
  final Color color;
  final Color foreground;
  final bool isDark;
  final bool isElder;
  final VoidCallback onTap;

  const _DoseStatusButton({
    required this.taken,
    required this.color,
    required this.foreground,
    required this.isDark,
    required this.isElder,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final label = taken ? 'Taken' : 'Mark as Taken';
    final takenForeground = isDark
        ? AppTheme.darkPrimaryForeground
        : AppTheme.primaryForeground;
    return Semantics(
      button: true,
      toggled: taken,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            constraints: BoxConstraints(
              minWidth: isElder ? 118 : 104,
              minHeight: 48,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: isElder ? 10 : 8,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: taken
                  ? color
                  : (isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : Colors.black.withValues(alpha: 0.04)),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: taken ? color : foreground,
                width: taken ? 1.5 : 2,
              ),
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: animation, child: child),
              ),
              child: Row(
                key: ValueKey(taken),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    taken ? Icons.check_rounded : Icons.check_circle_outline,
                    color: taken ? takenForeground : foreground,
                    size: isElder ? 21 : 18,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: AppTheme.textStyle(
                      color: taken ? takenForeground : foreground,
                      fontSize: isElder ? 13 : 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
