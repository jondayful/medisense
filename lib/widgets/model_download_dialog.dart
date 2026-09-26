import 'dart:async';

import 'package:flutter/material.dart';

import '../services/vosk_model_store.dart';

/// Reusable blocking sheet for the one-time offline Vosk model download.
/// Returns the absolute extracted model path, or null when the user cancels.
Future<String?> showModelDownloadDialog(
  BuildContext context, {
  required VoskModelStore store,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => ModelDownloadDialog(store: store),
  );
}

class ModelDownloadDialog extends StatefulWidget {
  const ModelDownloadDialog({super.key, required this.store});
  final VoskModelStore store;

  @override
  State<ModelDownloadDialog> createState() => _ModelDownloadDialogState();
}

class _ModelDownloadDialogState extends State<ModelDownloadDialog> {
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final path = await widget.store.prepare();
      if (mounted && !_closed) {
        _closed = true;
        Navigator.of(context).pop(path);
      }
    } on VoskDownloadCancelled {
      // The Cancel button owns dismissal. Keep any partial file for resume.
    } catch (_) {
      // The store notifies, causing the retry UI below to render.
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.store,
      builder: (context, _) {
        final store = widget.store;
        final received = _megabytes(store.receivedBytes);
        final total = store.totalBytes == null
            ? null
            : _megabytes(store.totalBytes!);
        final percent = store.progress == null
            ? null
            : (store.progress! * 100).clamp(0, 100).round();
        final hasError = store.error != null;

        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Offline voice package',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(
                  hasError
                      ? store.error!
                      : 'Downloading offline voice package for Tagalog/English commands (~320 MB)...',
                ),
                const SizedBox(height: 24),
                LinearProgressIndicator(value: hasError ? 0 : store.progress),
                const SizedBox(height: 10),
                Text(
                  total == null
                      ? '$received MB downloaded'
                      : '$percent%  •  $received MB / $total MB',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          _closed = true;
                          store.cancel();
                          Navigator.of(context).pop();
                        },
                        child: const Text('Cancel'),
                      ),
                    ),
                    if (hasError) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => unawaited(_prepare()),
                          child: const Text('Retry'),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
}
