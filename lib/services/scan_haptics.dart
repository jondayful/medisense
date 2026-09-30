import 'package:flutter/services.dart';

/// Distinct tactile cues for camera guidance and a completed label read.
enum ScanHapticPattern { noText, closer, farther, steady, detected, warning }

class ScanHaptics {
  static const MethodChannel _channel = MethodChannel('medisense/scan_haptics');

  int _generation = 0;

  Future<void> play(ScanHapticPattern pattern) async {
    final generation = ++_generation;
    try {
      // Android plays a full-strength waveform with real pulse durations.
      await _channel.invokeMethod<void>('play', pattern.name);
    } on MissingPluginException {
      // iOS and non-native test hosts use the platform's strongest impacts.
      await _fallback(pattern, generation);
    } on PlatformException {
      await _fallback(pattern, generation);
    }
  }

  Future<void> cancel() async {
    ++_generation;
    try {
      await _channel.invokeMethod<void>('cancel');
    } on MissingPluginException {
      // Flutter fallback pulses stop when the generation changes.
    } on PlatformException {
      // Haptics are best effort and never block the scan flow.
    }
  }

  Future<void> _fallback(ScanHapticPattern pattern, int generation) async {
    final gaps = switch (pattern) {
      ScanHapticPattern.noText || ScanHapticPattern.closer => <int>[],
      ScanHapticPattern.farther || ScanHapticPattern.steady => <int>[200],
      ScanHapticPattern.detected => <int>[240, 240],
      ScanHapticPattern.warning => <int>[300],
    };
    if (generation != _generation) return;
    await HapticFeedback.heavyImpact();
    for (final gap in gaps) {
      await Future<void>.delayed(Duration(milliseconds: gap));
      if (generation != _generation) return;
      await HapticFeedback.heavyImpact();
    }
  }
}
