import 'package:flutter/material.dart';

import '../data/database_helper.dart';
import '../theme/app_theme.dart';

/// Shows only an operation count. Medication details stay in the local outbox.
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

  void _refresh() {
    setState(() {
      _count = DatabaseHelper().queuedSyncOperationCount(widget.userId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: widget.contentPadding,
      leading: Icon(
        Icons.sync_rounded,
        color: widget.accent,
        size: widget.iconSize,
      ),
      title: Text(
        'Cloud sync queue',
        style: AppTheme.textStyle(
          fontSize: widget.titleSize,
          fontWeight: FontWeight.w700,
          color: widget.primary,
        ),
      ),
      subtitle: FutureBuilder<int>(
        future: _count,
        builder: (context, snapshot) {
          final message = switch (snapshot.connectionState) {
            ConnectionState.waiting => 'Checking queued changes…',
            _ when snapshot.hasError =>
              'Queue status unavailable on this device.',
            _ when (snapshot.data ?? 0) == 0 =>
              'No changes waiting on this device. This does not confirm delivery to another device.',
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
        onPressed: _refresh,
        icon: const Icon(Icons.refresh_rounded),
        tooltip: 'Refresh sync queue status',
      ),
    );
  }
}
