import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/medication.dart';
import '../providers/medication_provider.dart';
import '../providers/voice_navigation_provider.dart';
import '../theme/app_theme.dart';

/// Shows the confirmation flow for a voice "mark as taken" request. Never
/// acts on a single generic button: single due dose → explicit Yes/Cancel;
/// multiple due → pick which medicine, then confirm. Undo is offered after
/// the mark.
Future<void> showTakeConfirmSheet(BuildContext context) async {
  final voice = context.read<VoiceNavigationProvider>();
  final med = context.read<MedicationProvider>();
  final candidates = voice.pendingTakeCandidates;
  if (candidates == null || candidates.isEmpty) {
    voice.cancelTake();
    return;
  }

  ({Medication med, ScheduleTime s})? chosen;
  if (candidates.length == 1) {
    final ok = await _confirmOne(context, candidates.first);
    if (ok == true) chosen = candidates.first;
  } else {
    final picked = await _pickOne(context, candidates);
    if (picked != null && context.mounted) {
      final ok = await _confirmOne(context, picked);
      if (ok == true) chosen = picked;
    }
  }

  if (chosen == null) {
    voice.cancelTake();
    return;
  }
  final dose = chosen;

  final name = dose.med.name;
  voice.confirmTake(dose);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('$name marked as taken'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 10),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => med.toggleDoseStatus(dose.med.id, dose.s.id, false),
        ),
      ),
    );
}

/// A named voice removal is confirmed explicitly before the schedule changes.
Future<void> showRemoveMedicationConfirmDialog(BuildContext context) async {
  final voice = context.read<VoiceNavigationProvider>();
  final medication = voice.pendingRemovalMedication;
  if (medication == null) return;
  final remove = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Remove medication?'),
      content: Text('Remove ${medication.name} from your medication schedule?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (remove == true) {
    await voice.confirmRemoveMedication();
  } else {
    voice.cancelRemoveMedication();
  }
}

Future<bool?> _confirmOne(
  BuildContext context,
  ({Medication med, ScheduleTime s}) dose,
) {
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (context) => _ConfirmSheet(
      title: 'Mark as taken?',
      body: 'Mark ${dose.med.name} ${dose.med.dosage} as taken now?',
    ),
  );
}

Future<({Medication med, ScheduleTime s})?> _pickOne(
  BuildContext context,
  List<({Medication med, ScheduleTime s})> candidates,
) {
  return showModalBottomSheet<({Medication med, ScheduleTime s})>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => _PickSheet(candidates: candidates),
  );
}

class _ConfirmSheet extends StatelessWidget {
  final String title;
  final String body;

  const _ConfirmSheet({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? AppTheme.darkTextPrimary : AppTheme.textPrimary;
    final surface = isDark ? AppTheme.darkSurface : Colors.white;

    return Container(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 26, 24, 28),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: AppTheme.textStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: ink,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              body,
              style: AppTheme.textStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: ink,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 68,
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.check_rounded, size: 28),
                label: Text(
                  'Yes',
                  style: AppTheme.textStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.mint,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 60,
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(false),
                style: OutlinedButton.styleFrom(
                  foregroundColor: ink,
                  side: BorderSide(
                    color: ink.withValues(alpha: 0.35),
                    width: 2,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: Text(
                  'Cancel',
                  style: AppTheme.textStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: ink,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PickSheet extends StatelessWidget {
  final List<({Medication med, ScheduleTime s})> candidates;

  const _PickSheet({required this.candidates});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? AppTheme.darkTextPrimary : AppTheme.textPrimary;
    final muted = isDark ? AppTheme.darkTextSecondary : AppTheme.textSecondary;
    final surface = isDark ? AppTheme.darkSurface : Colors.white;

    return Container(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 26, 24, 28),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Which medicine did you take?',
              style: AppTheme.textStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'You have ${candidates.length} doses due.',
              style: AppTheme.textStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: muted,
              ),
            ),
            const SizedBox(height: 20),
            for (final dose in candidates)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SizedBox(
                  height: 68,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(dose),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.ink,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    child: Text(
                      '${dose.med.name} · ${dose.med.dosage} · ${dose.s.formattedTime}',
                      softWrap: true,
                      textAlign: TextAlign.center,
                      style: AppTheme.textStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            SizedBox(
              height: 60,
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: ink,
                  side: BorderSide(
                    color: ink.withValues(alpha: 0.35),
                    width: 2,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: Text(
                  'Cancel',
                  style: AppTheme.textStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: ink,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
