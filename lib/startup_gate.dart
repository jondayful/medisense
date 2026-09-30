import 'dart:async';

import 'package:flutter/material.dart';

/// Draws a Flutter frame before native storage and auth plugins finish loading.
class StartupGate extends StatefulWidget {
  const StartupGate({
    super.key,
    required this.initialize,
    required this.child,
    this.slowAfter = const Duration(seconds: 12),
    this.stalledAfter = const Duration(seconds: 30),
  });

  final Future<void> Function() initialize;
  final Widget child;
  final Duration slowAfter;
  final Duration stalledAfter;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  Timer? _slowTimer;
  Timer? _stalledTimer;
  bool _ready = false;
  bool _slow = false;
  bool _stalled = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    // Plugin calls must not delay the first Flutter frame on iOS.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _start();
    });
  }

  void _start() {
    _slowTimer?.cancel();
    _stalledTimer?.cancel();
    setState(() {
      _slow = false;
      _stalled = false;
      _failed = false;
    });
    final future = Future.sync(widget.initialize);
    _slowTimer = Timer(widget.slowAfter, () {
      if (mounted && !_ready && !_failed) setState(() => _slow = true);
    });
    _stalledTimer = Timer(widget.stalledAfter, () {
      if (mounted && !_ready && !_failed) setState(() => _stalled = true);
    });
    future.then(
      (_) {
        if (!mounted) return;
        _slowTimer?.cancel();
        _stalledTimer?.cancel();
        setState(() => _ready = true);
      },
      onError: (Object error, StackTrace stack) {
        debugPrint('App startup failed: $error\n$stack');
        if (!mounted) return;
        _slowTimer?.cancel();
        _stalledTimer?.cancel();
        setState(() => _failed = true);
      },
    );
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    _stalledTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.child;
    return MaterialApp(
      title: 'MediSense',
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('MediSense', style: TextStyle(fontSize: 26)),
                  const SizedBox(height: 24),
                  if (!_failed && !_stalled) const CircularProgressIndicator(),
                  if (_slow || _failed || _stalled) ...[
                    const SizedBox(height: 20),
                    Text(
                      _failed
                          ? 'MediSense could not start. Close and reopen the app.'
                          : _stalled
                          ? 'Startup did not finish. Close and reopen MediSense.'
                          : 'MediSense is taking longer than expected to start.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
