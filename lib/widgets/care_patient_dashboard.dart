import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/care_overview.dart';
import '../models/medication.dart';
import '../services/supabase_sync_service.dart';
import '../theme/app_theme.dart';

/// Cloud-backed care snapshot. No guardian-side SQLite copy is involved.
class CarePatientDashboard extends StatefulWidget {
  final String patientId;
  final bool large;

  const CarePatientDashboard({
    super.key,
    required this.patientId,
    required this.large,
  });

  @override
  State<CarePatientDashboard> createState() => _CarePatientDashboardState();
}

class _CarePatientDashboardState extends State<CarePatientDashboard> {
  late Future<CareOverview> _overview;
  String? _sendingSchedule;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant CarePatientDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.patientId != widget.patientId) {
      _sendingSchedule = null;
      _refresh();
    }
  }

  void _refresh() {
    final sync = SupabaseSyncService();
    _overview = Future.wait([
      sync.fetchPatientMedications(widget.patientId),
      sync.fetchPatientLogs(widget.patientId),
    ]).then((result) => CareOverview.fromCloud(result[0], result[1]));
  }

  Future<void> _sendReminder(CareDose dose) async {
    setState(() => _sendingSchedule = dose.scheduleId);
    try {
      await SupabaseSyncService().sendDoseReminder(
        patientId: widget.patientId,
        medicationId: dose.medicationId,
        scheduleId: dose.scheduleId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Reminder added to the patient inbox for ${dose.medicationName}.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not send the reminder. Check your connection and pairing.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _sendingSchedule = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.primaryTextColor(context);
    final muted = AppTheme.secondaryTextColor(context);
    final accent = Theme.of(context).brightness == Brightness.dark
        ? AppTheme.darkAccentGreen
        : AppTheme.accentGreen;
    final tint = Theme.of(context).brightness == Brightness.dark
        ? AppTheme.darkMuted
        : AppTheme.paper;
    final large = widget.large;
    return FutureBuilder<CareOverview>(
      future: _overview,
      builder: (context, snapshot) {
        if (!snapshot.hasData && !snapshot.hasError) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Column(
            children: [
              Text(
                'Could not load live patient data.',
                style: AppTheme.textStyle(color: primary),
              ),
              TextButton.icon(
                onPressed: () => setState(_refresh),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ],
          );
        }
        final overview = snapshot.data!;
        final now = DateTime.now();
        final notRecorded = overview.dueToday - overview.takenToday;
        final history = overview.lastSevenDaysTaken;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Today’s care',
                    style: AppTheme.textStyle(
                      fontSize: large ? 23 : 18,
                      fontWeight: FontWeight.w700,
                      color: primary,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh patient data',
                  onPressed: () => setState(_refresh),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            Text(
              'Cloud data checked ${DateFormat.jm().format(overview.refreshedAt)}',
              style: AppTheme.textStyle(
                fontSize: large ? 16 : 12,
                color: muted,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              'Changes appear after the patient device syncs.',
              style: AppTheme.textStyle(
                fontSize: large ? 15 : 12,
                color: muted,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(large ? 18 : 14),
              decoration: BoxDecoration(
                color: tint,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _summaryValue(
                      '${overview.takenToday} / ${overview.dueToday}',
                      'Doses taken',
                      primary,
                      muted,
                    ),
                  ),
                  Container(
                    height: 44,
                    width: 1,
                    color: AppTheme.borderColor(context),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _summaryValue(
                      '$notRecorded',
                      'Not recorded',
                      primary,
                      muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            Text(
              'Doses recorded · last 7 days',
              style: AppTheme.textStyle(
                fontSize: large ? 19 : 15,
                fontWeight: FontWeight.w700,
                color: primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Count of doses marked taken; not a clinical adherence score.',
              style: AppTheme.textStyle(
                fontSize: large ? 15 : 12,
                color: muted,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: large ? 78 : 72,
              child: Row(
                children: List.generate(7, (index) {
                  final day = DateTime(
                    now.year,
                    now.month,
                    now.day - (6 - index),
                  );
                  final count = history[index];
                  final isDark =
                      Theme.of(context).brightness == Brightness.dark;
                  final dayName = DateFormat.E().format(day);
                  final shortDay = dayName.length > 2
                      ? dayName.substring(0, 2)
                      : dayName;
                  return Expanded(
                    child: Semantics(
                      label:
                          '${DateFormat.yMMMMEEEEd().format(day)}: $count doses marked taken',
                      child: ExcludeSemantics(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: [
                            Container(
                              width: large ? 38 : 34,
                              height: large ? 38 : 34,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: count > 0 ? accent : tint,
                                border: Border.all(
                                  color: count > 0
                                      ? accent
                                      : AppTheme.borderColor(context),
                                  width: 1.5,
                                ),
                              ),
                              child: Text(
                                '$count',
                                style: AppTheme.tabular(
                                  fontSize: large ? 16 : 13,
                                  color: count > 0
                                      ? (isDark
                                            ? AppTheme.darkPrimaryForeground
                                            : AppTheme.primaryForeground)
                                      : primary,
                                ),
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              shortDay,
                              maxLines: 1,
                              style: AppTheme.textStyle(
                                fontSize: large ? 13 : 11,
                                color: muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
            const SizedBox(height: 22),
            CareDoseTimeline(
              key: ValueKey(widget.patientId),
              doses: overview.doses,
              large: large,
              sendingSchedule: _sendingSchedule,
              onNotify: _sendReminder,
            ),
          ],
        );
      },
    );
  }

  Widget _summaryValue(String value, String label, Color primary, Color muted) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: AppTheme.tabular(
            fontSize: widget.large ? 25 : 22,
            color: primary,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          softWrap: true,
          style: AppTheme.textStyle(
            fontSize: widget.large ? 15 : 12,
            color: muted,
          ),
        ),
      ],
    );
  }
}

/// Time-of-day pills keep the guardian's initial feed focused while preserving
/// access to every scheduled dose and its actual recorded intake time.
class CareDoseTimeline extends StatefulWidget {
  final List<CareDose> doses;
  final bool large;
  final String? sendingSchedule;
  final ValueChanged<CareDose> onNotify;

  const CareDoseTimeline({
    super.key,
    required this.doses,
    required this.large,
    required this.sendingSchedule,
    required this.onNotify,
  });

  @override
  State<CareDoseTimeline> createState() => _CareDoseTimelineState();
}

class _CareDoseTimelineState extends State<CareDoseTimeline> {
  String? _selectedBlock;

  String _initialBlock(Map<String, int> counts) {
    final blocks = ScheduleTime.blocks;
    final currentIndex = blocks.indexOf(
      ScheduleTime.labelFor(DateTime.now().hour),
    );
    for (var offset = 0; offset < blocks.length; offset++) {
      final block = blocks[(currentIndex + offset) % blocks.length];
      if (counts[block]! > 0) return block;
    }
    return 'all';
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.primaryTextColor(context);
    final muted = AppTheme.secondaryTextColor(context);
    final counts = <String, int>{
      for (final block in ScheduleTime.blocks) block: 0,
    };
    for (final dose in widget.doses) {
      final block = ScheduleTime.labelFor(dose.hour);
      counts[block] = counts[block]! + 1;
    }
    final selected = _selectedBlock ?? _initialBlock(counts);
    final visible = selected == 'all'
        ? widget.doses
        : widget.doses
              .where((dose) => ScheduleTime.labelFor(dose.hour) == selected)
              .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Today's schedule",
          style: AppTheme.textStyle(
            fontSize: widget.large ? 21 : 17,
            fontWeight: FontWeight.w700,
            color: primary,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          selected == 'all'
              ? '${widget.doses.length} scheduled today'
              : '${_fullLabel(selected)} · ${visible.length} scheduled',
          style: AppTheme.textStyle(
            fontSize: widget.large ? 16 : 13,
            color: muted,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: widget.large ? 60 : 50,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            itemCount: ScheduleTime.blocks.length + 1,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final block = index == 0 ? 'all' : ScheduleTime.blocks[index - 1];
              return _CareTimePill(
                label: _shortLabel(block),
                count: block == 'all' ? widget.doses.length : counts[block]!,
                selected: selected == block,
                large: widget.large,
                onTap: () => setState(() => _selectedBlock = block),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        if (visible.isEmpty)
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(widget.large ? 20 : 16),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? AppTheme.darkMuted
                  : AppTheme.paper,
              border: Border.all(color: AppTheme.borderColor(context)),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(
              widget.doses.isEmpty
                  ? 'No active medication schedules have synced yet.'
                  : 'No medicines scheduled for ${_fullLabel(selected)}. Choose another time above.',
              style: AppTheme.textStyle(
                fontSize: widget.large ? 17 : 14,
                color: muted,
              ),
            ),
          )
        else
          ...visible.map(
            (dose) => CareDoseCard(
              dose: dose,
              large: widget.large,
              sending: widget.sendingSchedule == dose.scheduleId,
              onNotify: widget.sendingSchedule == null
                  ? () => widget.onNotify(dose)
                  : null,
            ),
          ),
      ],
    );
  }

  String _shortLabel(String block) => switch (block) {
    'all' => 'All',
    'Morning' => 'Morn',
    'Afternoon' => 'Noon',
    'Evening' => 'Eve',
    _ => block,
  };

  String _fullLabel(String block) => block == 'Afternoon' ? 'Noon' : block;
}

class _CareTimePill extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final bool large;
  final VoidCallback onTap;

  const _CareTimePill({
    required this.label,
    required this.count,
    required this.selected,
    required this.large,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = dark ? AppTheme.darkSuccess : AppTheme.mint;
    final foreground = selected
        ? (dark ? Colors.black : Colors.white)
        : AppTheme.primaryTextColor(context);
    return Semantics(
      button: true,
      selected: selected,
      label: '$label, $count scheduled doses${selected ? ', selected' : ''}',
      child: Material(
        color: selected
            ? accent
            : (dark ? AppTheme.darkCardSurface : Colors.white),
        borderRadius: BorderRadius.circular(28),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(28),
          child: Container(
            constraints: BoxConstraints(minWidth: large ? 82 : 68),
            padding: EdgeInsets.symmetric(horizontal: large ? 16 : 13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
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
                    fontSize: large ? 17 : 13,
                    fontWeight: FontWeight.w700,
                    color: foreground,
                  ),
                ),
                const SizedBox(width: 7),
                Container(
                  constraints: const BoxConstraints(minWidth: 22),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? Colors.white.withValues(alpha: dark ? 0.12 : 0.2)
                        : accent.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$count',
                    textAlign: TextAlign.center,
                    style: AppTheme.tabular(
                      fontSize: large ? 15 : 12,
                      color: selected ? foreground : accent,
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

/// A single, readable dose row. The name has its own full-width line so the
/// scheduled time cannot force a mid-word break in large-text mode.
class CareDoseCard extends StatelessWidget {
  final CareDose dose;
  final bool large;
  final bool sending;
  final VoidCallback? onNotify;

  const CareDoseCard({
    super.key,
    required this.dose,
    required this.large,
    required this.sending,
    required this.onNotify,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = AppTheme.primaryTextColor(context);
    final muted = AppTheme.secondaryTextColor(context);
    final accent = isDark ? AppTheme.darkAccentGreen : AppTheme.accentGreen;
    final tint = isDark ? AppTheme.darkMuted : AppTheme.paper;
    final taken = dose.status == 'taken';
    final time = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay(hour: dose.hour, minute: dose.minute));
    final status = taken && dose.takenAt != null
        ? 'Marked taken at ${DateFormat.jm().format(dose.takenAt!)}'
        : 'Not recorded taken';
    final extremeText = MediaQuery.textScalerOf(context).scale(1) > 1.5;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.all(large ? 16 : 14),
      decoration: BoxDecoration(
        color: tint,
        border: Border.all(color: AppTheme.borderColor(context)),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 9,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  time,
                  style: AppTheme.tabular(
                    fontSize: large ? 16 : 13,
                    color: isDark
                        ? AppTheme.darkPrimaryForeground
                        : AppTheme.primaryForeground,
                  ),
                ),
              ),
              Text(
                status,
                softWrap: true,
                style: AppTheme.textStyle(
                  fontSize: large ? 15 : 12,
                  fontWeight: FontWeight.w600,
                  color: taken ? primary : muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Semantics(
            label: 'Medication: ${dose.medicationName}',
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                dose.medicationName,
                maxLines: 1,
                softWrap: false,
                style: AppTheme.textStyle(
                  fontSize: large ? 21 : 17,
                  fontWeight: FontWeight.w700,
                  color: primary,
                ),
              ),
            ),
          ),
          if (dose.dosage.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              dose.dosage,
              style: AppTheme.textStyle(
                fontSize: large ? 16 : 13,
                color: muted,
              ),
            ),
          ],
          if (!taken) ...[
            const SizedBox(height: 9),
            Semantics(
              label: 'Notify patient about ${dose.medicationName} at $time',
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: extremeText ? double.infinity : null,
                  child: OutlinedButton.icon(
                    onPressed: onNotify,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: primary,
                      side: BorderSide(color: accent, width: 1.5),
                      minimumSize: Size(0, large ? 52 : 48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: Icon(
                      Icons.notifications_active_outlined,
                      color: accent,
                      size: large ? 22 : 20,
                    ),
                    label: Text(
                      sending ? 'Sending…' : 'Notify patient',
                      style: AppTheme.textStyle(
                        fontSize: large ? 16 : 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
