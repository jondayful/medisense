import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../models/medication.dart';
import '../providers/medication_provider.dart';
import '../providers/notification_provider.dart';
import '../providers/tts_provider.dart';
import '../providers/app_state_provider.dart';
import '../providers/auth_provider.dart';
import '../services/medication_alarm_message.dart';
import '../theme/app_theme.dart';

class AlarmAlertScreen extends StatefulWidget {
  final String medicationId;
  final String scheduleId;

  const AlarmAlertScreen({
    super.key,
    required this.medicationId,
    required this.scheduleId,
  });

  @override
  State<AlarmAlertScreen> createState() => _AlarmAlertScreenState();
}

class _AlarmAlertScreenState extends State<AlarmAlertScreen> {
  Timer? _announcementTimer;
  Timer? _hapticTimer;
  TtsProvider? _tts;
  bool _feedbackStarted = false;
  bool _dismissed = false;

  @override
  void dispose() {
    _announcementTimer?.cancel();
    _hapticTimer?.cancel();
    _tts?.stop();
    super.dispose();
  }

  void _startAlarmFeedback(String medicationName) {
    if (_feedbackStarted || _dismissed) return;
    _feedbackStarted = true;
    // Android's foreground alarm service speaks even while Flutter is asleep.
    if (Platform.isAndroid) return;
    _tts = context.read<TtsProvider>();

    final appState = context.read<AppStateProvider>();
    final auth = context.read<AuthProvider>();
    final name = auth.isLoggedIn
        ? auth.userName.trim()
        : appState.onboardingName?.trim();
    final message = medicationAlarmMessage(
      name: name,
      medicineName: medicationName,
    );
    Future<void> announce() => _tts!.speakAlarm(message, message);

    announce();
    _announcementTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => announce(),
    );
    _hapticTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => HapticFeedback.heavyImpact(),
    );
  }

  Future<void> _markTaken() async {
    final notifications = context.read<NotificationProvider>();
    final medications = context.read<MedicationProvider>();
    final tts = context.read<TtsProvider>();
    final result = await medications.toggleDoseStatus(
      widget.medicationId,
      widget.scheduleId,
      true,
    );
    if (!mounted) return;
    if (result == DoseStatusChangeResult.expired ||
        result == DoseStatusChangeResult.recentlyTaken ||
        result == DoseStatusChangeResult.readOnly ||
        result == DoseStatusChangeResult.unavailable) {
      _dismissed = true;
      _announcementTimer?.cancel();
      _hapticTimer?.cancel();
      await notifications.dismissDoseAlarm(
        medicationId: widget.medicationId,
        scheduleId: widget.scheduleId,
      );
      await tts.speakAlarm(
        result == DoseStatusChangeResult.expired
            ? 'This medicine is expired. Do not take it.'
            : result == DoseStatusChangeResult.recentlyTaken
            ? 'This dose was marked as taken recently.'
            : 'I could not update this dose. Please ask your caregiver for help.',
        result == DoseStatusChangeResult.expired
            ? 'Expired na ang gamot na ito. Huwag itong inumin.'
            : result == DoseStatusChangeResult.recentlyTaken
            ? 'Naitala na ang dose na ito kamakailan.'
            : 'Hindi ko na-update ang dose na ito. Humingi ng tulong sa tagapag-alaga.',
      );
      if (mounted) context.go('/');
      return;
    }
    _dismissed = true;
    _announcementTimer?.cancel();
    _hapticTimer?.cancel();
    await notifications.dismissDoseAlarm(
      medicationId: widget.medicationId,
      scheduleId: widget.scheduleId,
    );
    if (mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final medication = context.watch<MedicationProvider>().getById(
      widget.medicationId,
    );
    if (medication == null) {
      return const Scaffold(
        body: Center(child: Text('Medication reminder unavailable')),
      );
    }
    ScheduleTime? schedule;
    for (final item in medication.schedule) {
      if (item.id == widget.scheduleId) {
        schedule = item;
        break;
      }
    }
    if (schedule == null) {
      return const Scaffold(
        body: Center(child: Text('Dose reminder unavailable')),
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startAlarmFeedback(medication.name);
    });

    final action = Theme.of(context).brightness == Brightness.dark
        ? AppTheme.elderDarkAction
        : AppTheme.elderAction;
    final page = AppTheme.pageColor(context);
    final ink = AppTheme.primaryTextColor(context);
    final muted = AppTheme.secondaryTextColor(context);
    final actionText = AppTheme.actionForegroundColor(context);

    return Scaffold(
      backgroundColor: page,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 36, 24, 28),
          child: Column(
            children: [
              const Spacer(),
              Semantics(
                header: true,
                child: Icon(Icons.alarm_rounded, size: 72, color: action),
              ),
              const SizedBox(height: 24),
              Text(
                'Time for your medicine',
                textAlign: TextAlign.center,
                style: AppTheme.textStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: ink,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                medication.name,
                textAlign: TextAlign.center,
                style: AppTheme.textStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${medication.dosage} ${medication.form}',
                textAlign: TextAlign.center,
                style: AppTheme.textStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  color: muted,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                schedule.formattedTime,
                style: AppTheme.bigNumber(fontSize: 42, color: ink),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 64,
                child: FilledButton.icon(
                  onPressed: () {
                    HapticFeedback.heavyImpact();
                    _markTaken();
                  },
                  icon: const Icon(Icons.check_rounded, size: 30),
                  label: const Text('Take Medicine'),
                  style: FilledButton.styleFrom(
                    backgroundColor: action,
                    foregroundColor: actionText,
                    textStyle: AppTheme.textStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 60,
                child: OutlinedButton.icon(
                  onPressed: () =>
                      context.go('/medication/${widget.medicationId}'),
                  icon: const Icon(Icons.info_outline_rounded, size: 28),
                  label: const Text('Details'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ink,
                    side: BorderSide(
                      color: ink.withValues(alpha: .55),
                      width: 2,
                    ),
                    minimumSize: const Size.fromHeight(48),
                    textStyle: AppTheme.textStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
