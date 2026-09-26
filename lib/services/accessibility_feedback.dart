import 'package:flutter/services.dart';

/// Small, platform-native feedback cues used by Vision Loss mode.
/// Keeping these cues in one place makes tactile and audio landmarks
/// consistent without adding a heavyweight audio dependency.
class AccessibilityFeedback {
  const AccessibilityFeedback._();

  static void selection() {
    HapticFeedback.selectionClick();
    SystemSound.play(SystemSoundType.click);
  }

  static void listeningStarted() {
    HapticFeedback.mediumImpact();
    SystemSound.play(SystemSoundType.alert);
  }

  static void voiceOpened() {
    HapticFeedback.heavyImpact();
    SystemSound.play(SystemSoundType.alert);
  }

  static void voiceResolved() {
    HapticFeedback.mediumImpact();
    SystemSound.play(SystemSoundType.click);
  }

  static void listeningLandmark() {
    HapticFeedback.selectionClick();
    SystemSound.play(SystemSoundType.click);
  }

  static void pageChanged() {
    HapticFeedback.selectionClick();
    SystemSound.play(SystemSoundType.click);
  }

  static void doseCompleted() {
    HapticFeedback.mediumImpact();
    SystemSound.play(SystemSoundType.alert);
  }

  static void error() {
    HapticFeedback.heavyImpact();
    SystemSound.play(SystemSoundType.alert);
  }
}
