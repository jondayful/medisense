import 'package:flutter/material.dart';
import 'medi_bottom_nav.dart';

/// Large-text wrapper around the shared floating tab bar. Keeping one tab-bar
/// implementation prevents the accessibility mode from drifting visually or
/// taking a different performance path.
class ElderBottomNav extends StatelessWidget {
  final String currentRoute;
  final bool dark;
  final bool visionLoss;

  const ElderBottomNav({
    super.key,
    required this.currentRoute,
    this.dark = false,
    this.visionLoss = false,
  });

  @override
  Widget build(BuildContext context) {
    return MediBottomNav(
      currentRoute: currentRoute,
      dark: dark,
      visionLoss: visionLoss,
      large: true,
    );
  }
}
