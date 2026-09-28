import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/accessibility_mode.dart';
import '../providers/app_state_provider.dart';
import '../providers/medication_provider.dart';
import '../providers/notification_provider.dart';
import '../theme/app_theme.dart';

class NotificationSettingsSheet extends StatefulWidget {
  const NotificationSettingsSheet({super.key});

  @override
  State<NotificationSettingsSheet> createState() =>
      _NotificationSettingsSheetState();
}

class _NotificationSettingsSheetState extends State<NotificationSettingsSheet> {
  bool _busy = false;

  Future<void> _setEnabled(bool enabled) async {
    final state = context.read<AppStateProvider>();
    if (_busy || state.notificationsEnabled == enabled) return;
    setState(() => _busy = true);
    try {
      if (enabled) {
        final allowed = await context
            .read<NotificationProvider>()
            .ensureAlarmPermissions();
        if (!mounted) return;
        if (!allowed) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Allow notifications and alarms in device settings.',
              ),
            ),
          );
          return;
        }
      }
      state.toggleNotifications();
      await context.read<MedicationProvider>().syncMedicationAlarms();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = context.watch<AppStateProvider>().notificationsEnabled;
    final large = context
        .watch<AppStateProvider>()
        .accessibilityMode
        .usesLargeText;
    final primary = AppTheme.primaryTextColor(context);
    final secondary = AppTheme.secondaryTextColor(context);
    final action = AppTheme.actionColor(context);

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 16, 20, large ? 28 : 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: action.withValues(alpha: .12),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.notifications_active_outlined, color: action),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Notification settings',
              textAlign: TextAlign.center,
              style: AppTheme.textStyle(
                fontSize: large ? 28 : 23,
                fontWeight: FontWeight.w700,
                color: primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Choose whether MediSense reminds you when a dose is due.',
              textAlign: TextAlign.center,
              style: AppTheme.textStyle(
                fontSize: large ? 19 : 15,
                height: 1.4,
                color: secondary,
              ),
            ),
            const SizedBox(height: 20),
            Container(
              decoration: BoxDecoration(
                color: AppTheme.surfaceColor(context),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppTheme.borderColor(context)),
              ),
              child: SwitchListTile.adaptive(
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: large ? 8 : 4,
                ),
                activeTrackColor: action,
                title: Text(
                  'Medication reminders',
                  style: AppTheme.textStyle(
                    fontSize: large ? 21 : 17,
                    fontWeight: FontWeight.w700,
                    color: primary,
                  ),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    enabled
                        ? 'Dose alarms are on for your schedule.'
                        : 'Dose alarms are currently off.',
                    style: AppTheme.textStyle(
                      fontSize: large ? 17 : 14,
                      height: 1.35,
                      color: secondary,
                    ),
                  ),
                ),
                value: enabled,
                onChanged: _busy ? null : _setEnabled,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: Size.fromHeight(large ? 60 : 52),
                foregroundColor: action,
                side: BorderSide(color: AppTheme.borderColor(context)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                textStyle: TextStyle(fontSize: large ? 18 : 15),
              ),
              onPressed: _busy
                  ? null
                  : () => context
                        .read<NotificationProvider>()
                        .openExactAlarmSettings(),
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Device alarm permissions'),
            ),
            if (_busy) ...[
              const SizedBox(height: 16),
              const Center(child: CircularProgressIndicator()),
            ],
          ],
        ),
      ),
    );
  }
}
