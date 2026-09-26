import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';
import '../providers/medication_provider.dart';
import '../providers/app_state_provider.dart';
import '../models/accessibility_mode.dart';
import '../models/medication.dart';

import '../widgets/add_medication_modal.dart';
import '../services/accessibility_feedback.dart';

class MedicationDetailScreen extends StatelessWidget {
  final String medicationId;

  const MedicationDetailScreen({super.key, required this.medicationId});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MedicationProvider>();
    final medication = provider.getById(medicationId);
    final accessibilityMode = context
        .watch<AppStateProvider>()
        .accessibilityMode;
    final isVisionLoss = accessibilityMode.isVisionLoss;
    final isElder = accessibilityMode.isElder || isVisionLoss;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final detailText = isDark
        ? AppTheme.darkAccessibleSecondary
        : AppTheme.textPrimary;
    final detailValue = isDark
        ? AppTheme.darkAccessibleText
        : AppTheme.textPrimary;
    final successColor = isDark ? AppTheme.darkSuccess : AppTheme.success;
    final warningColor = isDark ? AppTheme.darkWarning : AppTheme.warning;
    final errorColor = isDark ? AppTheme.darkError : AppTheme.error;

    if (medication == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('MediSense')),
        body: const Center(child: Text('Medication not found')),
      );
    }

    final appBar = AppBar(
      backgroundColor: isElder
          ? (isDark ? AppTheme.elderDarkPaper : AppTheme.paper)
          : null,
      foregroundColor: isElder
          ? (isDark ? AppTheme.elderDarkInk : AppTheme.ink)
          : null,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded),
        onPressed: () => context.go('/schedule'),
      ),
      title: const Text('MediSense'),
      actions: [
        TextButton.icon(
          onPressed: () {
            showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              useSafeArea: true,
              backgroundColor: Colors.transparent,
              builder: (context) =>
                  AddMedicationModal(initialMedication: medication),
            );
          },
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Edit'),
          style: TextButton.styleFrom(
            foregroundColor: isElder
                ? (isDark ? AppTheme.elderDarkAction : AppTheme.elderAction)
                : (isDark
                      ? AppTheme.darkAccessibleSecondary
                      : AppTheme.primaryDark),
            minimumSize: const Size(88, 48),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            textStyle: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );

    return Scaffold(
      appBar: appBar,
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(20, isElder ? 12 : 20, 20, 110),
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: medication.color.withAlpha(25),
                    borderRadius: BorderRadius.circular(AppTheme.cardRadius),
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: medication.color.withAlpha(40),
                          borderRadius: BorderRadius.circular(
                            AppTheme.cardRadius,
                          ),
                        ),
                        child: Center(
                          child: Text(
                            medication.name[0],
                            style: TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w700,
                              color: medication.color,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        medication.name,
                        textAlign: TextAlign.center,
                        softWrap: true,
                        style: AppTheme.textStyle(
                          fontSize: isElder ? 32 : 26,
                          fontWeight: FontWeight.w800,
                          color: detailValue,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${medication.dosage} ${medication.form}',
                        textAlign: TextAlign.center,
                        style: AppTheme.textStyle(
                          fontSize: isElder ? 22 : 16,
                          color: detailText,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Details',
                          style: AppTheme.textStyle(
                            fontSize: isElder ? 26 : 20,
                            fontWeight: FontWeight.w800,
                            color: detailValue,
                          ),
                        ),
                        const Divider(height: 24),
                        _DetailRow(
                          icon: Icons.medication_rounded,
                          label: 'Dosage',
                          value: medication.dosage,
                        ),
                        if (medication.parsedDosage?.isAmbiguous == true)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  size: 24,
                                  color: warningColor,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Dosage unit not confirmed. Check the label before taking.',
                                    style: AppTheme.textStyle(
                                      color: warningColor,
                                      fontSize: isElder ? 17 : 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 16),
                        _DetailRow(
                          icon: Icons.square_rounded,
                          label: 'Form',
                          value: medication.form,
                        ),
                        const SizedBox(height: 16),
                        _DetailRow(
                          icon: Icons.calendar_today_rounded,
                          label: 'Expiration',
                          value: medication.expirationDate == null
                              ? 'Not recorded'
                              : '${medication.expirationDate!.month}/${medication.expirationDate!.day}/${medication.expirationDate!.year}',
                          valueColor: medication.isExpired ? errorColor : null,
                        ),
                        if (medication.isExpired)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  size: 24,
                                  color: errorColor,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'This medication has expired!',
                                    style: AppTheme.textStyle(
                                      color: errorColor,
                                      fontSize: 19,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (medication.schedule.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Schedule',
                            style: AppTheme.textStyle(
                              fontSize: isElder ? 26 : 20,
                              fontWeight: FontWeight.w800,
                              color: detailValue,
                            ),
                          ),
                          const Divider(height: 24),
                          ...medication.schedule.asMap().entries.map((entry) {
                            final idx = entry.key;
                            final s = entry.value;
                            return Padding(
                              padding: EdgeInsets.only(
                                bottom: idx < medication.schedule.length - 1
                                    ? 12
                                    : 0,
                              ),
                              child: Semantics(
                                button: true,
                                label:
                                    '${s.label} ${s.formattedTime}, ${s.taken ? 'taken' : 'pending'}. Tap to mark as ${s.taken ? 'pending' : 'taken'}',
                                child: Material(
                                  color: Colors.transparent,
                                  borderRadius: BorderRadius.circular(16),
                                  child: InkWell(
                                    onTap: () {
                                      AccessibilityFeedback.selection();
                                      provider.toggleTaken(medication.id, idx);
                                    },
                                    borderRadius: BorderRadius.circular(16),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 8,
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 40,
                                            height: 40,
                                            decoration: BoxDecoration(
                                              color: s.taken
                                                  ? successColor.withAlpha(30)
                                                  : warningColor.withAlpha(24),
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: s.taken
                                                    ? successColor
                                                    : AppTheme.subtleTextColor(
                                                        context,
                                                      ),
                                                width: s.taken ? 2 : 2.5,
                                              ),
                                            ),
                                            child: Icon(
                                              s.taken
                                                  ? Icons.check_circle_rounded
                                                  : Icons
                                                        .radio_button_unchecked_rounded,
                                              color: s.taken
                                                  ? successColor
                                                  : AppTheme.subtleTextColor(
                                                      context,
                                                    ),
                                              size: 26,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  s.label,
                                                  style: AppTheme.textStyle(
                                                    fontSize: isElder ? 21 : 16,
                                                    fontWeight: FontWeight.w700,
                                                    color: detailValue,
                                                  ),
                                                ),
                                                Text(
                                                  s.formattedTime,
                                                  style: AppTheme.tabular(
                                                    fontSize: isElder ? 19 : 15,
                                                    color: detailText,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: s.taken
                                                  ? successColor.withAlpha(24)
                                                  : warningColor.withAlpha(28),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              border: Border.all(
                                                color: s.taken
                                                    ? successColor.withAlpha(
                                                        150,
                                                      )
                                                    : warningColor.withAlpha(
                                                        180,
                                                      ),
                                                width: 1.5,
                                              ),
                                            ),
                                            child: Text(
                                              s.taken ? 'Taken' : 'Pending',
                                              style: TextStyle(
                                                fontSize: isElder ? 18 : 14,
                                                fontWeight: FontWeight.w600,
                                                color: s.taken
                                                    ? successColor
                                                    : warningColor,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ),
                ],
                if (medication.notes.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Notes',
                            style: AppTheme.textStyle(
                              fontSize: isElder ? 26 : 20,
                              fontWeight: FontWeight.w800,
                              color: detailValue,
                            ),
                          ),
                          const Divider(height: 24),
                          Text(
                            medication.notes,
                            style: AppTheme.textStyle(
                              fontSize: isElder ? 21 : 16,
                              color: detailText,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _confirmDelete(context, medication),
                    icon: Icon(Icons.delete_outline, color: errorColor),
                    label: Text(
                      'Remove Medication',
                      style: TextStyle(color: errorColor),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      side: BorderSide(color: errorColor),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, Medication medication) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final errorColor = isDark ? AppTheme.darkError : AppTheme.error;
    final primaryText = AppTheme.primaryTextColor(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Medication'),
        content: Text(
          'Are you sure you want to remove ${medication.name} from your schedule?',
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: primaryText,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text(
                      'Cancel',
                      maxLines: 1,
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: () {
                      context.read<MedicationProvider>().removeMedication(
                        medication.id,
                      );
                      Navigator.of(ctx).pop();
                      context.go('/schedule');
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('${medication.name} removed'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: errorColor,
                      foregroundColor: isDark
                          ? AppTheme.darkSecondaryForeground
                          : Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text(
                      'Remove',
                      maxLines: 1,
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mode = context.watch<AppStateProvider>().accessibilityMode;
    final isLarge = mode.isElder || mode.isVisionLoss;
    final labelColor = isDark
        ? AppTheme.darkAccessibleSecondary
        : AppTheme.inkText;
    final valueColorForTheme = isDark
        ? AppTheme.darkAccessibleText
        : AppTheme.textPrimary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: isLarge ? 28 : 24, color: labelColor),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: Text(
            label,
            style: AppTheme.textStyle(
              fontSize: isLarge ? 20 : 15,
              fontWeight: FontWeight.w600,
              color: labelColor,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 3,
          child: Text(
            value,
            textAlign: TextAlign.end,
            softWrap: true,
            style: AppTheme.textStyle(
              fontSize: isLarge ? 21 : 16,
              fontWeight: FontWeight.w600,
              color: valueColor ?? valueColorForTheme,
            ),
          ),
        ),
      ],
    );
  }
}
