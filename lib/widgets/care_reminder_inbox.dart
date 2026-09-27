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
          padding: EdgeInsets.all(widget.large ? 20 : 16),
          decoration: BoxDecoration(
            color: AppTheme.surfaceColor(context),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.borderColor(context)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.notifications_active_outlined, color: accent),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      'Guardian reminders',
                      style: AppTheme.textStyle(
                        fontSize: widget.large ? 21 : 16,
                        fontWeight: FontWeight.w700,
                        color: primary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ...snapshot.data!.take(3).map((reminder) {
                final medId = reminder['medication_id']?.toString();
                final matches = meds.where((med) => med.id == medId);
                final med = matches.isEmpty ? null : matches.first;
                final guardianName =
                    reminder['guardian_name']?.toString().split(' ').first ??
                    'Guardian';
                final sentAt = DateTime.tryParse(
                  reminder['created_at']?.toString() ?? '',
                )?.toLocal();
                final detail = med?.name ?? 'medicine';
                return Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$guardianName is reminding you.\nTake your $detail',
                        style: AppTheme.textStyle(
                          fontSize: widget.large ? 18 : 14,
                          fontWeight: FontWeight.w700,
                          color: primary,
                        ),
                      ),
                      Text(
                        sentAt == null
                            ? 'Reminder received'
                            : DateFormat.MMMd().add_jm().format(sentAt),
                        style: AppTheme.textStyle(
                          fontSize: widget.large ? 16 : 12,
                          color: muted,
                        ),
                      ),
                    ],
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
