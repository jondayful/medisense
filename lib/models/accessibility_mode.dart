import 'package:flutter/material.dart';

enum AccessibilityMode { none, elder, visionLoss }

extension AccessibilityModeX on AccessibilityMode {
  String get label {
    switch (this) {
      case AccessibilityMode.elder:
        return 'Large Text';
      case AccessibilityMode.visionLoss:
        return 'Vision Loss';
      case AccessibilityMode.none:
        return 'Standard';
    }
  }

  String get description {
    switch (this) {
      case AccessibilityMode.elder:
        return 'Large text, big buttons, simplified layout. Voice optional.';
      case AccessibilityMode.visionLoss:
        return 'Voice-guided navigation. Press the mic button to speak commands.';
      case AccessibilityMode.none:
        return 'Standard touch-based interface with default sizing.';
    }
  }

  IconData get icon {
    switch (this) {
      case AccessibilityMode.elder:
        return Icons.accessibility_new_rounded;
      case AccessibilityMode.visionLoss:
        return Icons.visibility_off_rounded;
      case AccessibilityMode.none:
        return Icons.person_rounded;
    }
  }

  String get storageKey => 'accessibilityMode';

  String get persistedValue => name;

  bool get isElder => this == AccessibilityMode.elder;
  bool get isVisionLoss => this == AccessibilityMode.visionLoss;
  bool get usesLargeText => isElder || isVisionLoss;
  bool get isNone => this == AccessibilityMode.none;

  static AccessibilityMode fromString(String value) {
    return AccessibilityMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => AccessibilityMode.none,
    );
  }
}
