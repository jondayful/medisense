import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../providers/medication_provider.dart';
import '../providers/notification_provider.dart';
import '../providers/app_state_provider.dart';
import '../providers/tts_provider.dart';
import '../models/accessibility_mode.dart';
import '../models/medication.dart';
import '../models/dosage.dart';
import '../services/medicine_expiry_parser.dart';
import '../services/prescription_safety.dart';
import 'expiry_month_picker.dart';
import 'expiry_date_scanner.dart';

class AddMedicationModal extends StatefulWidget {
  final Medication? initialMedication;
  final String? initialName;
  final String? initialDosage;
  final String? initialFrequency;
  final TimeOfDay? initialTime;
  final DateTime? initialExpirationDate;
  final int? initialQuantityDispensed;
  final double? initialUnitsPerDose;
  final bool promptForExpirationScan;
  final VoidCallback? onSaved;

  const AddMedicationModal({
    super.key,
    this.initialMedication,
    this.initialName,
    this.initialDosage,
    this.initialFrequency,
    this.initialTime,
    this.initialExpirationDate,
    this.initialQuantityDispensed,
    this.initialUnitsPerDose,
    this.promptForExpirationScan = false,
    this.onSaved,
  });

  @override
  State<AddMedicationModal> createState() => _AddMedicationModalState();
}

class _ElderTimePickerDialog extends StatefulWidget {
  final TimeOfDay initialTime;

  const _ElderTimePickerDialog({required this.initialTime});

  @override
  State<_ElderTimePickerDialog> createState() => _ElderTimePickerDialogState();
}

class _ElderTimePickerDialogState extends State<_ElderTimePickerDialog> {
  late int _hour;
  late int _minute;
  late DayPeriod _period;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialTime;
    _hour = initial.hourOfPeriod == 0 ? 12 : initial.hourOfPeriod;
    _minute = initial.minute;
    _period = initial.period;
  }

  TimeOfDay get _selectedTime {
    final hour24 = (_hour % 12) + (_period == DayPeriod.pm ? 12 : 0);
    return TimeOfDay(hour: hour24 % 24, minute: _minute);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? AppTheme.darkTextPrimary : AppTheme.primaryDark;
    final accent = isDark ? AppTheme.darkAccentGreen : AppTheme.primaryDark;
    final surface = isDark ? AppTheme.darkSurface : Colors.white;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      backgroundColor: surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                Expanded(
                  child: Text(
                    'Choose a time',
                    textAlign: TextAlign.center,
                    style: AppTheme.textStyle(
                      color: ink,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, _selectedTime),
                  style: TextButton.styleFrom(foregroundColor: accent),
                  child: const Text(
                    'Done',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 196,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  IgnorePointer(
                    child: Container(
                      height: 46,
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _Wheel(
                          values: List.generate(12, (i) => '${i + 1}'),
                          initial: _hour - 1,
                          ink: ink,
                          onChanged: (i) => setState(() => _hour = i + 1),
                        ),
                      ),
                      Expanded(
                        child: _Wheel(
                          values: List.generate(
                            60,
                            (i) => i.toString().padLeft(2, '0'),
                          ),
                          initial: _minute,
                          ink: ink,
                          onChanged: (i) => setState(() => _minute = i),
                        ),
                      ),
                      Expanded(
                        child: _Wheel(
                          values: const ['AM', 'PM'],
                          initial: _period == DayPeriod.am ? 0 : 1,
                          ink: ink,
                          onChanged: (i) => setState(
                            () =>
                                _period = i == 0 ? DayPeriod.am : DayPeriod.pm,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Text(
              'Scroll to set the time',
              style: AppTheme.textStyle(
                fontSize: 13,
                color: isDark ? AppTheme.darkTextSecondary : AppTheme.mutedText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Wheel extends StatelessWidget {
  const _Wheel({
    required this.values,
    required this.initial,
    required this.ink,
    required this.onChanged,
  });
  final List<String> values;
  final int initial;
  final Color ink;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => CupertinoPicker.builder(
    scrollController: FixedExtentScrollController(initialItem: initial),
    itemExtent: 46,
    selectionOverlay: const SizedBox.shrink(),
    onSelectedItemChanged: (index) {
      HapticFeedback.selectionClick();
      onChanged(index % values.length);
    },
    childCount: values.length,
    itemBuilder: (_, index) => Center(
      child: Text(
        values[index],
        style: AppTheme.textStyle(
          fontSize: 26,
          fontWeight: FontWeight.w800,
          color: ink,
        ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
      ),
    ),
  );
}

const List<String> _forms = [
  'Tablet',
  'Capsule',
  'Syrup',
  'Injection',
  'Cream',
  'Ointment',
  'Drops',
  'Suspension',
  'Inhaler',
  'Patch',
];

class _AddMedicationModalState extends State<AddMedicationModal> {
  final _nameCtrl = TextEditingController();
  final _dosageCtrl = TextEditingController();
  final _quantityCtrl = TextEditingController();
  final _unitsPerDoseCtrl = TextEditingController();
  String? _dosageUnit;
  String? _dosageStrength;
  String? _dosageRaw;
  bool _dosageEdited = false;

  bool get _usesLargeText =>
      context.read<AppStateProvider>().accessibilityMode.usesLargeText;
  String? _selectedFrequency = 'Once a day';
  TimeOfDay? _selectedTime;
  DateTime? _selectedExpirationDate;
  DateTime? _originalExpirationDate;
  DateTime? _scannedExpirationDate;
  bool _expirationEdited = false;
  bool _expirationPromptHandled = false;
  bool _saving = false;
  final _expirationCtrl = TextEditingController();
  String _selectedForm = 'Tablet';
  final Map<String, bool> _preservedTaken = {};

  @override
  void initState() {
    super.initState();
    _dosageCtrl.addListener(() => _dosageEdited = true);
    _selectedExpirationDate =
        widget.initialMedication?.expirationDate ??
        widget.initialExpirationDate;
    _originalExpirationDate = _selectedExpirationDate;
    if (_selectedExpirationDate != null) {
      _expirationCtrl.text = _formatExpiration(_selectedExpirationDate!);
    }
    if (widget.initialMedication != null) {
      _nameCtrl.text = widget.initialMedication!.name;
      _selectedForm = widget.initialMedication!.form;
      _prefillDosage(widget.initialMedication!.dosage);

      _selectedFrequency = widget.initialMedication!.frequency;
      _quantityCtrl.text =
          widget.initialMedication!.quantityDispensed?.toString() ?? '';
      _unitsPerDoseCtrl.text =
          widget.initialMedication!.unitsPerDose?.toString() ?? '';

      if (widget.initialMedication!.schedule.isNotEmpty) {
        _selectedTime = widget.initialMedication!.schedule.first.time;
      }

      for (var s in widget.initialMedication!.schedule) {
        _preservedTaken[s.id] = s.taken;
      }
    } else if (widget.initialName != null) {
      _nameCtrl.text = widget.initialName!;
    }

    if (widget.initialDosage != null) {
      _prefillDosage(widget.initialDosage!);
    }

    if (widget.initialFrequency != null) {
      _selectedFrequency = widget.initialFrequency;
    }

    if (widget.initialTime != null) {
      _selectedTime = widget.initialTime;
    }
    if (widget.initialQuantityDispensed != null) {
      _quantityCtrl.text = widget.initialQuantityDispensed.toString();
    }
    if (widget.initialUnitsPerDose != null) {
      _unitsPerDoseCtrl.text = widget.initialUnitsPerDose.toString();
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _quantityCtrl.dispose();
    _unitsPerDoseCtrl.dispose();
    _expirationCtrl.dispose();
    super.dispose();
  }

  final List<String> _frequencies = kFrequencyOptions;

  Future<void> _pickTime() async {
    final picked = await showDialog<TimeOfDay>(
      context: context,
      builder: (context) {
        return _ElderTimePickerDialog(
          initialTime: _selectedTime ?? TimeOfDay.now(),
        );
      },
    );
    if (picked != null && mounted) {
      setState(() => _selectedTime = picked);
      await _offerExpirationScanAfterTime();
    }
  }

  Future<void> _offerExpirationScanAfterTime() async {
    if (!widget.promptForExpirationScan ||
        _expirationPromptHandled ||
        _expirationCtrl.text.trim().isNotEmpty) {
      return;
    }
    _expirationPromptHandled = true;
    final shouldScan = await _askToScanExpiration(_nameCtrl.text.trim());
    if (!mounted) return;
    if (shouldScan == true) await _scanExpirationDate();
  }

  Future<void> _pickExpirationDate() async {
    final picked = await showExpiryMonthPicker(
      context,
      initialDate: _selectedExpirationDate,
      largeText: _usesLargeText,
    );
    if (picked != null && mounted) {
      setState(() {
        _expirationEdited = true;
        _scannedExpirationDate = null;
        _selectedExpirationDate = picked;
        _expirationCtrl.text = _formatExpiration(picked);
      });
    }
  }

  Future<void> _scanExpirationDate() async {
    final result = await ExpiryDateScannerScreen.open(context);
    if (result == null || !mounted) return;
    final effectiveDate = result.effectiveExpirationDate;
    setState(() {
      _expirationEdited = true;
      _scannedExpirationDate = effectiveDate;
      _selectedExpirationDate = effectiveDate;
      _expirationCtrl.text = _formatExpiration(effectiveDate);
    });
  }

  String _formatExpiration(DateTime date) =>
      '${date.month.toString().padLeft(2, '0')}/${date.year.toString().padLeft(4, '0')}';

  void _prefillDosage(String source) {
    final parsed = Dosage.parse(source);
    if (parsed == null) {
      _dosageCtrl.text = source;
      _dosageUnit = null;
      _dosageStrength = null;
      _dosageRaw = null;
      return;
    }
    _dosageCtrl.text = parsed.value != null
        ? Dosage.formatNumber(parsed.value!)
        : source;
    _dosageUnit = parsed.unit;
    _dosageStrength = parsed.strength;
    _dosageRaw = parsed.raw;
    _dosageEdited = false;
  }

  bool get _isInsulinName {
    final n = _nameCtrl.text.toLowerCase();
    return ['insulin', 'lantus', 'novorapid', 'humalog'].any(n.contains);
  }

  /// Insulin is dosed in units, not mL or mg. Force an explicit choice before
  /// saving anything that is not `units` — never silently convert.
  Future<bool> _confirmInsulinDose() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Insulin dose check'),
        content: Text(
          'Insulin is normally measured in units, not mg or mL. '
          'You selected "${_dosageUnit ?? 'no unit'}" for this insulin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('keep'),
            child: Text('Keep ${_dosageUnit ?? 'none'}'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('units'),
            child: const Text('Use units'),
          ),
        ],
      ),
    );
    if (choice == 'units') {
      setState(() => _dosageUnit = 'units');
      return true;
    }
    return choice == 'keep';
  }

  String _dosageString() {
    final rawText = _dosageCtrl.text.trim();
    final value = double.tryParse(rawText.replaceAll(',', '.'));
    if (_dosageEdited) {
      if (value != null && _dosageUnit != null) {
        return '${Dosage.formatNumber(value)} $_dosageUnit';
      }
      if (_dosageRaw != null && _dosageRaw!.isNotEmpty) return _dosageRaw!;
      return rawText;
    }
    if (_dosageStrength != null && _dosageStrength!.isNotEmpty) {
      return _dosageStrength!;
    }
    if (value != null && _dosageUnit != null) {
      return '${Dosage.formatNumber(value)} $_dosageUnit';
    }
    if (_dosageRaw != null && _dosageRaw!.isNotEmpty) return _dosageRaw!;
    return rawText;
  }

  Future<bool?> _askToScanExpiration(String medicineName) async {
    final appState = context.read<AppStateProvider>();
    final english =
        'Would you like to scan the expiration date for $medicineName?';
    final filipino =
        'Gusto mo bang i-scan ang expiration date ng $medicineName?';
    final large = appState.accessibilityMode.usesLargeText;
    final isFilipino = appState.isFilipino;
    final prompt = showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(isFilipino ? 'Petsa ng expiration' : 'Expiration date'),
        content: Text(
          isFilipino ? filipino : english,
          style: TextStyle(fontSize: large ? 21 : 17, height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(isFilipino ? 'Laktawan' : 'Skip'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.camera_alt_outlined),
            label: Text(isFilipino ? 'I-scan' : 'Scan now'),
          ),
        ],
      ),
    );
    if (appState.voiceNavigationEnabled) {
      unawaited(context.read<TtsProvider>().speak(english, filipino));
    }
    final answer = await prompt;
    if (mounted && appState.voiceNavigationEnabled) {
      await context.read<TtsProvider>().stop();
    }
    return answer;
  }

  Future<void> _saveMedication() async {
    if (_saving) return;
    _saving = true;
    try {
      await _saveMedicationOnce();
    } finally {
      _saving = false;
    }
  }

  Future<void> _saveMedicationOnce() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    final dosageValue = _dosageCtrl.text.trim();
    if (dosageValue.isEmpty || _dosageUnit == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Enter the medicine strength and choose its unit before saving.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (_isInsulinName && _dosageUnit != 'units') {
      final confirmed = await _confirmInsulinDose();
      if (!confirmed || !mounted) return;
    }
    if (widget.promptForExpirationScan && _selectedTime == null) {
      await _pickTime();
      return;
    }
    if (widget.promptForExpirationScan &&
        !_expirationPromptHandled &&
        _expirationCtrl.text.trim().isEmpty) {
      await _offerExpirationScanAfterTime();
      if (!mounted) return;
    }
    final expirationInput = _expirationCtrl.text.trim();
    final expiration = expirationInput.isEmpty
        ? null
        : !_expirationEdited && _originalExpirationDate != null
        ? _originalExpirationDate
        : _scannedExpirationDate != null &&
              expirationInput == _formatExpiration(_scannedExpirationDate!)
        ? _scannedExpirationDate
        : MedicineExpiryParser.parseManual(expirationInput);
    if (expirationInput.isNotEmpty && expiration == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a real expiration month in MM/YYYY format.'),
        ),
      );
      return;
    }
    _selectedExpirationDate = expiration;
    _selectedTime ??= const TimeOfDay(hour: 8, minute: 0);

    final provider = context.read<MedicationProvider>();
    final isEdit = widget.initialMedication != null;
    final medId =
        widget.initialMedication?.id ??
        DateTime.now().millisecondsSinceEpoch.toString();

    final color =
        widget.initialMedication?.color ??
        AppTheme.medicationColors[provider.medications.length %
            AppTheme.medicationColors.length];

    final schedules = ScheduleTime.buildSchedule(
      medId: medId,
      start: _selectedTime!,
      frequency: _selectedFrequency ?? 'Once a day',
      preservedTaken: _preservedTaken,
    );

    final newMed = Medication(
      id: medId,
      name: name,
      dosage: _dosageString(),
      form: _selectedForm,
      expirationDate: _selectedExpirationDate,
      color: color,
      schedule: schedules,
      frequency: _selectedFrequency ?? 'Once a day',
      quantityDispensed: int.tryParse(_quantityCtrl.text.trim()),
      unitsPerDose: double.tryParse(_unitsPerDoseCtrl.text.trim()),
      prescriptionStartDate: DateTime.now(),
      // Saving this page is the explicit review step; OCR alone never marks
      // a regimen as reviewed.
      prescriptionReviewed: true,
    );

    // A scan may lead here after a low-confidence read or a manual edit.
    // Recheck the final name and strength before writing a second record.
    if (!isEdit && widget.initialName != null) {
      final existing = PrescriptionSafety.findMatchingMedication(
        scannedName: newMed.name,
        scannedStrength: newMed.dosage,
        activeMedications: provider.medications,
      );
      if (existing != null) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Already in your schedule'),
            content: Text(
              '${existing.name} ${existing.dosage} is already saved. '
              'Open your schedule to change the existing entry.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        return;
      }
    }

    final notifications = context.read<NotificationProvider>();
    final alarmsEnabled = context.read<AppStateProvider>().notificationsEnabled;
    final hasScheduledAlarm = alarmsEnabled && newMed.schedule.isNotEmpty;
    if (hasScheduledAlarm) {
      final alarmReady = await notifications.ensureAlarmPermissions();
      if (!mounted) return;
      if (!alarmReady) {
        await _showAlarmPermissionSheet(
          notifications,
          newMed.schedule.first.time,
        );
        return;
      }
    }

    final alarmTimeLabel = hasScheduledAlarm
        ? newMed.schedule.first.time.format(context)
        : null;

    try {
      if (isEdit) {
        await provider.editMedication(newMed);
      } else {
        await provider.addMedication(newMed);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Android could not confirm the reminder alarm. The medication may '
            'already be saved. Check alarm access, then save the schedule again.',
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 8),
        ),
      );
      return;
    }

    if (!mounted) return;

    widget.onSaved?.call();
    Navigator.of(context).pop();

    _showAlarmToast(
      hasScheduledAlarm
          ? isEdit
                ? '${newMed.name} updated · Alarm set for $alarmTimeLabel'
                : 'Alarm set for $alarmTimeLabel'
          : newMed.schedule.isEmpty
          ? isEdit
                ? '${newMed.name} updated · As needed, no timed alarm'
                : 'Medicine saved · As needed, no timed alarm'
          : isEdit
          ? '${newMed.name} updated · Reminders are off'
          : 'Medication saved · Reminders are off',
    );
  }

  void _showAlarmToast(String message) {
    final navigator = Navigator.of(context, rootNavigator: true);
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (context, animation, secondaryAnimation) => SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Material(
              color: AppTheme.inkText,
              borderRadius: BorderRadius.circular(999),
              elevation: 8,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    style: AppTheme.textStyle(
                      color: AppTheme.primaryForeground,
                      fontSize: _usesLargeText ? 17 : 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -0.8),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
          child: child,
        );
      },
    );
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (navigator.mounted && navigator.canPop()) {
        navigator.pop();
      }
    });
  }

  Future<void> _showAlarmPermissionSheet(
    NotificationProvider notifications,
    TimeOfDay time,
  ) async {
    final timeLabel = time.format(context);
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.alarm_rounded,
                  size: 32,
                  color: AppTheme.subtleTextColor(sheetContext),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Allow medication alarms',
                    style: AppTheme.textStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.subtleTextColor(sheetContext),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'MediSense needs notification, exact alarm, and full-screen alarm access to ring at $timeLabel. Enable these in Android Settings, return here, then save the schedule again.',
              style: AppTheme.textStyle(
                fontSize: 17,
                height: 1.35,
                color: AppTheme.subtleTextColor(sheetContext),
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: () async {
                  await notifications.openExactAlarmSettings();
                  if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                },
                icon: const Icon(Icons.settings_rounded),
                label: const Text('Enable Alarm Access'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: TextButton(
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: const Text('Not now'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _surfaceColor(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark
        ? AppTheme.darkInputSurface
        : Colors.white;
  }

  Color _accentColor(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark
        ? AppTheme.darkInputSurface
        : AppTheme.primaryAccent;
  }

  Color _formTextColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? AppTheme.darkAccessibleSecondary
        : AppTheme.primaryDark;
  }

  Color _formLabelColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? AppTheme.darkAccessibleText
        : AppTheme.primaryDark;
  }

  Color _formBorderColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? AppTheme.darkInputBorder
        : AppTheme.primaryDark.withValues(alpha: 0.18);
  }

  @override
  Widget build(BuildContext context) {
    final surface = _surfaceColor(context);
    final accent = _accentColor(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final action = isDark ? AppTheme.darkAccentGreen : AppTheme.success;
    final actionText = isDark ? AppTheme.darkPrimaryForeground : Colors.white;

    return SafeArea(
      top: true,
      bottom: false,
      child: Padding(
        // Keep the sheet header visibly below the consumed notch/punch-hole
        // inset instead of letting the title sit on the hardware boundary.
        padding: const EdgeInsets.only(top: 16),
        child: Container(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          ),
          padding: EdgeInsets.only(
            top: 12,
            left: 24,
            right: 24,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        widget.initialMedication != null
                            ? 'Edit Medication'
                            : 'Add Medication',
                        style: AppTheme.textStyle(
                          color: _formLabelColor(context),
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Semantics(
                      button: true,
                      label: 'Cancel and close',
                      child: IconButton(
                        tooltip: 'Cancel and close',
                        icon: const Icon(Icons.close_rounded),
                        iconSize: 26,
                        color: _formTextColor(context),
                        constraints: const BoxConstraints.tightFor(
                          width: 48,
                          height: 48,
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _buildInputGroup(
                  'Medicine Name',
                  Icons.medical_services_outlined,
                  'e.g. Biogesic',
                  _nameCtrl,
                ),
                const SizedBox(height: 16),
                _buildDosageControl(),
                const SizedBox(height: 16),
                _buildExpirationDateControl(accent),
                const SizedBox(height: 16),
                _buildFormDropdown(accent),
                const SizedBox(height: 16),
                _buildFrequencyDropdown(accent),
                const SizedBox(height: 16),
                _buildPrescriptionSupplyFields(accent),
                const SizedBox(height: 16),
                _buildTimePicker(accent),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: action,
                      foregroundColor: actionText,
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 0,
                    ),
                    onPressed: _saveMedication,
                    child: Text(
                      'SAVE SCHEDULE',
                      style: AppTheme.textStyle(
                        color: actionText,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    'CANCEL',
                    style: AppTheme.textStyle(
                      color: _formTextColor(context),
                      fontSize: _usesLargeText ? 18 : 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
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

  Widget _buildExpirationDateControl(Color accent) {
    return Container(
      decoration: BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _formBorderColor(context), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              'Expiration month (optional)',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          Row(
            children: [
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _expirationCtrl,
                  keyboardType: TextInputType.datetime,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9/]')),
                    LengthLimitingTextInputFormatter(7),
                  ],
                  decoration: const InputDecoration(
                    hintText: 'MM/YYYY',
                    border: InputBorder.none,
                  ),
                  onChanged: (value) => setState(() {
                    _expirationEdited = true;
                    _scannedExpirationDate = null;
                    _selectedExpirationDate = MedicineExpiryParser.parseManual(
                      value,
                    );
                  }),
                ),
              ),
              if (_expirationCtrl.text.isNotEmpty)
                IconButton(
                  tooltip: 'Clear expiration date',
                  onPressed: () => setState(() {
                    _expirationEdited = true;
                    _scannedExpirationDate = null;
                    _expirationCtrl.clear();
                    _selectedExpirationDate = null;
                  }),
                  icon: const Icon(Icons.clear_rounded),
                  color: _formTextColor(context),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickExpirationDate,
                    icon: const Icon(Icons.edit_calendar_rounded),
                    label: const Text('Month'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _formTextColor(context),
                      minimumSize: Size.fromHeight(_usesLargeText ? 56 : 48),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      textStyle: TextStyle(fontSize: _usesLargeText ? 18 : 15),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _scanExpirationDate,
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Scan EXP'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _formTextColor(context),
                      minimumSize: Size.fromHeight(_usesLargeText ? 56 : 48),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      textStyle: TextStyle(fontSize: _usesLargeText ? 18 : 15),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_scannedExpirationDate != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'Scanned expiration: ${MedicineExpiryParser.formatStored(_scannedExpirationDate!)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (!_expirationEdited &&
              _originalExpirationDate != null &&
              _originalExpirationDate!.day !=
                  DateTime(
                    _originalExpirationDate!.year,
                    _originalExpirationDate!.month + 1,
                    0,
                  ).day)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'Exact date from scan: ${MedicineExpiryParser.formatStored(_originalExpirationDate!)}. Kept unless you change it.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFormDropdown(Color accent) {
    return Container(
      decoration: BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _formBorderColor(context), width: 1.2),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Icon(
            Icons.category_rounded,
            color: _formTextColor(context),
            size: 24,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _selectedForm,
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
              dropdownColor: Theme.of(context).brightness == Brightness.dark
                  ? AppTheme.darkInputSurface
                  : Colors.white,
              borderRadius: BorderRadius.circular(16),
              style: AppTheme.textStyle(
                color: _formTextColor(context),
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
              items: _forms.map((f) {
                return DropdownMenuItem(value: f, child: Text(f));
              }).toList(),
              onChanged: (value) {
                if (value != null) setState(() => _selectedForm = value);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFrequencyDropdown(Color accent) {
    return Container(
      decoration: BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _formBorderColor(context), width: 1.2),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Icon(Icons.refresh, color: _formTextColor(context), size: 24),
          const SizedBox(width: 16),
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _selectedFrequency,
              hint: Text(
                'Select Frequency',
                style: AppTheme.textStyle(
                  color: _formTextColor(context),
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              icon: Icon(
                Icons.keyboard_arrow_down,
                color: _formTextColor(context),
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
              dropdownColor: Theme.of(context).brightness == Brightness.dark
                  ? AppTheme.darkInputSurface
                  : Colors.white,
              borderRadius: BorderRadius.circular(16),
              style: AppTheme.textStyle(
                color: _formTextColor(context),
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
              items: _frequencies.map((freq) {
                return DropdownMenuItem(value: freq, child: Text(freq));
              }).toList(),
              onChanged: (value) => setState(() => _selectedFrequency = value),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrescriptionSupplyFields(Color accent) {
    final textColor = _formTextColor(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _buildSupplyField(
            label: 'Total Quantity',
            hint: 'e.g. 30',
            controller: _quantityCtrl,
            keyboardType: TextInputType.number,
            textColor: textColor,
            fillColor: accent,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildSupplyField(
            label: 'Per Dose',
            hint: 'e.g. 1',
            controller: _unitsPerDoseCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textColor: textColor,
            fillColor: accent,
          ),
        ),
      ],
    );
  }

  Widget _buildSupplyField({
    required String label,
    required String hint,
    required TextEditingController controller,
    required TextInputType keyboardType,
    required Color textColor,
    required Color fillColor,
  }) {
    final borderColor = _formBorderColor(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.visible,
            style: AppTheme.textStyle(
              color: _formLabelColor(context),
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 56,
          child: TextField(
            controller: controller,
            keyboardType: keyboardType,
            textInputAction: TextInputAction.next,
            style: AppTheme.textStyle(
              color: textColor,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
            decoration: InputDecoration(
              filled: true,
              fillColor: fillColor,
              hintText: hint,
              hintStyle: AppTheme.textStyle(
                color: AppTheme.subtleTextColor(context),
                fontSize: 17,
                fontWeight: FontWeight.w500,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: borderColor, width: 1.2),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: borderColor, width: 1.2),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: _accentColor(context), width: 2),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTimePicker(Color accent) {
    return GestureDetector(
      onTap: _pickTime,
      child: Container(
        decoration: BoxDecoration(
          color: accent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _formBorderColor(context), width: 1.2),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            Icon(Icons.schedule, color: _formTextColor(context), size: 24),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                _selectedTime != null
                    ? 'Start Time: ${ScheduleTime.formatTime(_selectedTime!)}'
                    : 'Select Start Time',
                style: AppTheme.textStyle(
                  color: _formTextColor(context),
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            Icon(Icons.access_time, color: _formTextColor(context), size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildDosageControl() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Dosage',
              style: AppTheme.textStyle(
                color: _formTextColor(context),
                fontSize: _usesLargeText ? 18 : 14,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              _dosagePreview(),
              style: AppTheme.textStyle(
                color: _formTextColor(context),
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: _accentColor(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _formBorderColor(context), width: 1.2),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextField(
            controller: _dosageCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: AppTheme.textStyle(
              fontWeight: FontWeight.w700,
              fontSize: 18,
              color: _formTextColor(context),
            ),
            decoration: InputDecoration(
              hintText: 'e.g. 5',
              border: InputBorder.none,
              isDense: true,
            ),
          ),
        ),
        if (_dosageStrength != null && _dosageStrength!.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(
                Icons.info_outline,
                size: 18,
                color: AppTheme.darkAccessibleSecondary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Label: $_dosageStrength',
                  style: AppTheme.textStyle(
                    color: _formTextColor(context),
                    fontSize: _usesLargeText ? 17 : 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        Text(
          'Unit',
          style: AppTheme.textStyle(
            color: _formLabelColor(context),
            fontSize: _usesLargeText ? 18 : 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: _accentColor(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _formBorderColor(context)),
          ),
          child: DropdownButtonFormField<String>(
            initialValue: Dosage.kUnits.contains(_dosageUnit)
                ? _dosageUnit
                : null,
            isExpanded: true,
            icon: const Icon(Icons.expand_more_rounded),
            decoration: const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
            hint: Text(
              'Select the unit on the label',
              style: AppTheme.textStyle(
                color: _formTextColor(context),
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            style: AppTheme.textStyle(
              color: _formTextColor(context),
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
            dropdownColor: _surfaceColor(context),
            borderRadius: BorderRadius.circular(16),
            items: [
              for (final unit in Dosage.kUnits)
                DropdownMenuItem<String>(value: unit, child: Text(unit)),
            ],
            onChanged: (unit) {
              if (unit == null) return;
              setState(() {
                _dosageUnit = unit;
                _dosageEdited = true;
              });
            },
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() {
              _dosageUnit = null;
              _dosageEdited = true;
            }),
            icon: const Icon(Icons.help_outline_rounded, size: 19),
            label: const Text('I’m not sure of the unit'),
            style: TextButton.styleFrom(
              foregroundColor: _formTextColor(context),
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              textStyle: AppTheme.textStyle(
                fontSize: _usesLargeText ? 17 : 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _dosagePreview() {
    final rawText = _dosageCtrl.text.trim();
    final value = double.tryParse(rawText.replaceAll(',', '.'));
    if (value != null && _dosageUnit != null) {
      return '${Dosage.formatNumber(value)} $_dosageUnit';
    }
    if (_dosageStrength != null && _dosageStrength!.isNotEmpty) {
      return _dosageStrength!;
    }
    if (_dosageRaw != null && _dosageRaw!.isNotEmpty) return _dosageRaw!;
    return rawText.isEmpty ? 'Not set' : rawText;
  }

  Widget _buildInputGroup(
    String label,
    IconData icon,
    String hint,
    TextEditingController controller,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTheme.textStyle(
            color: _formLabelColor(context),
            fontSize: _usesLargeText ? 18 : 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: _accentColor(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _formBorderColor(context), width: 1.2),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(icon, color: _formTextColor(context), size: 24),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: controller,
                  style: AppTheme.textStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                    color: _formTextColor(context),
                  ),
                  decoration: InputDecoration(
                    hintText: hint,
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
