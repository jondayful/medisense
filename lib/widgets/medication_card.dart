import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:provider/provider.dart';
import '../models/medication.dart';
import '../theme/app_theme.dart';
import '../providers/medication_provider.dart';
import '../services/accessibility_feedback.dart';
import '../services/medication_semantics.dart';
import 'pill_tile.dart';

class MedicationCard extends StatelessWidget {
  final Medication medication;
  final VoidCallback? onTap;

  /// When set, only the doses that belong to this time block are emphasised
  /// (amber) and the rest are dimmed — the card reads as part of a filtered
  /// day strip.
  final String? filterLabel;
  final bool isElder;

  const MedicationCard({
    super.key,
    required this.medication,
    this.onTap,
    this.filterLabel,
    this.isElder = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chipScale = isElder ? 1.35 : 1.0;
    final cardColor = isDark
        ? (isElder ? AppTheme.elderDarkCard : AppTheme.darkCardSurface)
        : Colors.white;
    final nameColor = isElder
        ? (isDark ? AppTheme.elderDarkInk : AppTheme.elderInk)
        : (isDark ? AppTheme.darkTextPrimary : AppTheme.textPrimary);
    final subColor = isElder
        ? (isDark ? AppTheme.elderDarkMuted : AppTheme.elderMuted)
        : (isDark ? AppTheme.darkTextSecondary : AppTheme.textSecondary);

    final pending = medication.schedule.where((s) => !s.taken).toList();
    Future<void> changeDoseStatus(ScheduleTime schedule, bool taken) async {
      final result = await context.read<MedicationProvider>().toggleDoseStatus(
        medication.id,
        schedule.id,
        taken,
      );
      if (result == DoseStatusChangeResult.updated) {
        if (taken) AccessibilityFeedback.doseCompleted();
        return;
      }
      if (result == DoseStatusChangeResult.alreadySet || !context.mounted) {
        return;
      }
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
    }

    return Semantics(
      container: true,
      button: onTap != null,
      label: medicationSemanticsLabel(medication, filterLabel: filterLabel),
      hint: onTap == null
          ? 'Swipe right to mark the next dose as taken'
          : 'Double-tap to view details. Swipe right to mark the next dose as taken.',
      customSemanticsActions: pending.isEmpty
          ? null
          : {
              CustomSemanticsAction(label: 'Mark as taken'): () {
                final schedule = pending.first;
                unawaited(changeDoseStatus(schedule, true));
              },
            },
      child: ExcludeSemantics(
        child: Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(AppTheme.cardRadius),
            border: Border.all(
              color: AppTheme.borderColor(context),
              width: isElder ? 2 : 1,
            ),
          ),
          child: InkWell(
            onTap: onTap == null
                ? null
                : () {
                    AccessibilityFeedback.selection();
                    onTap!();
                  },
            borderRadius: BorderRadius.circular(AppTheme.cardRadius),
            child: Padding(
              padding: EdgeInsets.all(isElder ? 24 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      PillTile(color: medication.color, isElder: isElder),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              medication.name,
                              softWrap: true,
                              style: AppTheme.textStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: isElder ? 26 : 17,
                                color: nameColor,
                              ),
                            ),
                            Text(
                              '${medication.dosage} ${medication.form} · '
                              '${medication.schedule.length} dose'
                              '${medication.schedule.length == 1 ? '' : 's'} today',
                              style: AppTheme.textStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: isElder ? 20 : 13,
                                color: subColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: subColor,
                        size: 24,
                      ),
                    ],
                  ),
                  SizedBox(height: isElder ? 18 : 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: medication.schedule.map((s) {
                      final active =
                          filterLabel != null && s.label == filterLabel;
                      final dimmed =
                          filterLabel != null && s.label != filterLabel;
                      return Opacity(
                        opacity: dimmed ? 0.45 : 1,
                        child: _DoseChip(
                          schedule: s,
                          scale: chipScale,
                          isElder: isElder,
                          active: active,
                          onPop: () => unawaited(changeDoseStatus(s, !s.taken)),
                        ),
                      );
                    }).toList(),
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

class _DoseChip extends StatefulWidget {
  final ScheduleTime schedule;
  final double scale;
  final bool active;
  final bool isElder;
  final VoidCallback onPop;

  const _DoseChip({
    required this.schedule,
    required this.scale,
    required this.active,
    this.isElder = false,
    required this.onPop,
  });

  @override
  State<_DoseChip> createState() => _DoseChipState();
}

class _DoseChipState extends State<_DoseChip> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isElder = widget.isElder;
    final done = isElder
        ? (isDark ? AppTheme.elderDarkDone : AppTheme.elderDone)
        : (isDark ? AppTheme.darkSuccess : AppTheme.success);
    final now = isElder
        ? (isDark ? AppTheme.elderDarkAction : AppTheme.elderAction)
        : (isDark ? AppTheme.darkFoil : AppTheme.foil);
    final s = widget.schedule;

    Color bg = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.04);
    Color fg = isElder
        ? (isDark ? AppTheme.elderDarkMuted : AppTheme.elderMuted)
        : (isDark ? AppTheme.darkTextSecondary : AppTheme.textSecondary);
    Color border = Colors.transparent;
    IconData? icon;

    if (s.taken) {
      bg = done.withValues(alpha: 0.14);
      fg = done;
      border = done.withValues(alpha: 0.35);
      icon = Icons.check_rounded;
    } else if (widget.active) {
      bg = now.withValues(alpha: 0.14);
      fg = now;
      border = now.withValues(alpha: 0.5);
    }

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onPop,
      child: AnimatedScale(
        // Keep feedback subtle so the chip does not visually jump away from
        // the user's finger or disturb the surrounding rhythm.
        scale: _pressed ? 0.97 : 1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: isElder ? 56 : 48),
          child: Container(
            alignment: Alignment.center,
            padding: EdgeInsets.symmetric(
              horizontal: 12 * widget.scale,
              vertical: 7 * widget.scale,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(20 * widget.scale),
              border: Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16 * widget.scale, color: fg),
                  const SizedBox(width: 4),
                ],
                Text(
                  s.formattedTime,
                  style: AppTheme.tabular(
                    fontSize: 13 * widget.scale,
                    fontWeight: FontWeight.w800,
                    color: fg,
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
