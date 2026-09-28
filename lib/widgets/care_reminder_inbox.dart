import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../providers/medication_provider.dart';
import '../services/supabase_sync_service.dart';
import '../theme/app_theme.dart';

/// Patient-side inbox for dose-specific messages from a connected guardian.
class CareReminderInbox extends StatefulWidget {
  final String patientId;
  final bool large;

  const CareReminderInbox({
    super.key,
    required this.patientId,
    this.large = false,
  });

  @override
  State<CareReminderInbox> createState() => _CareReminderInboxState();
}

class _CareReminderInboxState extends State<CareReminderInbox>
    with WidgetsBindingObserver {
  late Future<List<Map<String, dynamic>>> _reminders;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _startPolling();
    }
  }

  @override
  void didUpdateWidget(covariant CareReminderInbox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.patientId != oldWidget.patientId) {
      _refresh();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.resumed) {
      setState(_refresh);
      _startPolling();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _poll?.cancel();
      _poll = null;
    }
  }

  void _startPolling() {
    if (_poll != null) return;
    _poll = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(_refresh);
    });
  }

  void _refresh() {
    _reminders = SupabaseSyncService().fetchMyCareReminders(widget.patientId);
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final meds = context.watch<MedicationProvider>().medications;
    final primary = AppTheme.primaryTextColor(context);
    final muted = AppTheme.secondaryTextColor(context);
    final accent = Theme.of(context).brightness == Brightness.dark
        ? AppTheme.darkAccentGreen
        : AppTheme.accentGreen;
    final large = widget.large;
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _reminders,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return TextButton.icon(
            onPressed: () => setState(_refresh),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Care reminders unavailable · Retry'),
          );
        }
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const SizedBox.shrink();
        }
        return Container(
          width: double.infinity,
          padding: EdgeInsets.all(large ? 20 : 16),
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? AppTheme.darkCardSurface
                : const Color(0xFFF2F5EF),
            borderRadius: BorderRadius.circular(large ? 22 : 18),
            border: Border.all(
              color: accent.withValues(alpha: .55),
              width: 1.3,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: large ? 44 : 36,
                    height: large ? 44 : 36,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: .16),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.notifications_active_outlined,
                      color: accent,
                      size: large ? 25 : 21,
                    ),
                  ),
                  SizedBox(width: large ? 12 : 9),
                  Expanded(
                    child: Text(
                      'Guardian reminders',
                      style: AppTheme.textStyle(
                        fontSize: large ? 23 : 16,
                        fontWeight: FontWeight.w700,
                        color: primary,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: large ? 12 : 8),
              ...snapshot.data!.take(3).map((reminder) {
                final medId = reminder['medication_id']?.toString();
                final matches = meds.where((med) => med.id == medId);
                final med = matches.isEmpty ? null : matches.first;
                final rawGuardianName = reminder['guardian_name']
                    ?.toString()
                    .trim();
                final guardianName =
                    rawGuardianName == null || rawGuardianName.isEmpty
                    ? 'Your guardian'
                    : rawGuardianName.split(RegExp(r'\s+')).first;
                final scheduleId = reminder['schedule_id']?.toString();
                final scheduleMatches = med?.schedule.where(
                  (item) => item.id == scheduleId,
                );
                final schedule =
                    scheduleMatches == null || scheduleMatches.isEmpty
                    ? null
                    : scheduleMatches.first;
                final sentAt = DateTime.tryParse(
                  reminder['created_at']?.toString() ?? '',
                )?.toLocal();
                return Padding(
                  padding: EdgeInsets.only(top: large ? 12 : 10),
                  child: Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(large ? 16 : 12),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceColor(context),
                      borderRadius: BorderRadius.circular(large ? 18 : 14),
                      border: Border.all(color: AppTheme.borderColor(context)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$guardianName sent a dose reminder',
                          style: AppTheme.textStyle(
                            fontSize: large ? 18 : 14,
                            fontWeight: FontWeight.w700,
                            color: primary,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          med?.name ?? 'Scheduled medicine',
                          style: AppTheme.textStyle(
                            fontSize: large ? 23 : 17,
                            fontWeight: FontWeight.w700,
                            height: 1.25,
                            color: primary,
                          ),
                        ),
                        if (med?.dosage.trim().isNotEmpty ?? false) ...[
                          const SizedBox(height: 2),
                          Text(
                            med!.dosage,
                            style: AppTheme.textStyle(
                              fontSize: large ? 19 : 14,
                              color: muted,
                            ),
                          ),
                        ],
                        const SizedBox(height: 7),
                        Text(
                          schedule == null
                              ? 'Dose time unavailable'
                              : 'Scheduled dose: ${schedule.formattedTime}',
                          style: AppTheme.textStyle(
                            fontSize: large ? 19 : 14,
                            fontWeight: FontWeight.w600,
                            color: accent,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          sentAt == null
                              ? 'Reminder received'
                              : 'Received ${DateFormat.MMMd().add_jm().format(sentAt)}',
                          style: AppTheme.textStyle(
                            fontSize: large ? 16 : 12,
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }
}
