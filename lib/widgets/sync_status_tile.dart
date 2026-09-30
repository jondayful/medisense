import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/database_helper.dart';
import '../providers/medication_provider.dart';
import '../services/supabase_service.dart';
import '../services/supabase_sync_service.dart';
import '../theme/app_theme.dart';

/// Shows connection and medicine counts without exposing medication details.
class SyncStatusTile extends StatefulWidget {
  const SyncStatusTile({
    super.key,
    required this.userId,
    required this.contentPadding,
    required this.titleSize,
    required this.captionSize,
    required this.iconSize,
    required this.accent,
    required this.primary,
    required this.secondary,
  });

  final String userId;
  final EdgeInsets contentPadding;
  final double titleSize;
  final double captionSize;
  final double iconSize;
  final Color accent;
  final Color primary;
  final Color secondary;

  @override
  State<SyncStatusTile> createState() => _SyncStatusTileState();
}

class _SyncStatusTileState extends State<SyncStatusTile> {
  late Future<int> _count;
  bool _refreshing = false;
  bool _refreshFailed = false;

  @override
  void initState() {
    super.initState();
    _count = DatabaseHelper().queuedSyncOperationCount(widget.userId);
  }

  @override
  void didUpdateWidget(covariant SyncStatusTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId) {
      _count = DatabaseHelper().queuedSyncOperationCount(widget.userId);
    }
  }

  String? get _connectionProblem {
    if (!SupabaseService.isConfigured) {
      return 'Cloud sync is unavailable in this app build. Medicines stay on this device.';
    }
    if (SupabaseSyncService.nullableUuid(widget.userId) == null ||
        SupabaseService.client.auth.currentUser?.id != widget.userId) {
      return 'This account has no active cloud session. Sign out and sign in again to restore saved medicines.';
    }
    return null;
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _refreshFailed = false;
    });
    try {
      if (_connectionProblem == null) {
        await context.read<MedicationProvider>().syncNow();
      }
    } catch (_) {
      _refreshFailed = true;
    } finally {
      if (mounted) {
        setState(() {
          _count = DatabaseHelper().queuedSyncOperationCount(widget.userId);
          _refreshing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final medications = context.watch<MedicationProvider>();
    return ListTile(
      contentPadding: widget.contentPadding,
      leading: Icon(
        Icons.sync_rounded,
        color: widget.accent,
        size: widget.iconSize,
      ),
      title: Text(
        'Cloud sync',
        style: AppTheme.textStyle(
          fontSize: widget.titleSize,
          fontWeight: FontWeight.w700,
          color: widget.primary,
        ),
      ),
      subtitle: FutureBuilder<int>(
        future: _count,
        builder: (context, snapshot) {
          final message =
              _connectionProblem ??
              (_refreshFailed || medications.syncFailed
                  ? 'Cloud sync could not finish. Check your connection and try again.'
                  : null) ??
              switch (snapshot.connectionState) {
                ConnectionState.waiting => 'Checking queued changes…',
                _ when snapshot.hasError =>
                  'Queue status unavailable on this device.',
                _
                    when (snapshot.data ?? 0) == 0 &&
                        medications.cloudMedicationCount != null =>
                  '${medications.cloudMedicationCount} medicine${medications.cloudMedicationCount == 1 ? '' : 's'} found in cloud; ${medications.medications.length} on this device.',
                _ when (snapshot.data ?? 0) == 0 =>
                  'No changes waiting. Tap refresh to check for saved cloud medicines.',
                _ =>
                  '${snapshot.data} change${snapshot.data == 1 ? '' : 's'} waiting. The app retries when signed in and connected; delivery time is not guaranteed.',
              };
          return Text(
            message,
            style: AppTheme.textStyle(
              fontSize: widget.captionSize,
              color: widget.secondary,
              height: 1.3,
            ),
          );
        },
      ),
      trailing: IconButton(
        onPressed: _refreshing ? null : _refresh,
        icon: _refreshing
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.refresh_rounded),
        tooltip: 'Retry medicine cloud sync',
      ),
    );
  }
}
