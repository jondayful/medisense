import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// A capsule-shaped medicine tile: the one shape every user already knows.
class PillTile extends StatelessWidget {
  final Color color;
  final bool isElder;
  final double? width;
  final String form;

  const PillTile({
    super.key,
    required this.color,
    this.isElder = false,
    this.width,
    this.form = 'Tablet',
  });

  IconData get _formIcon {
    switch (form.toLowerCase()) {
      case 'syrup':
      case 'drops':
      case 'suspension':
        return Icons.medication_liquid_rounded;
      case 'injection':
        return Icons.vaccines_rounded;
      case 'cream':
      case 'ointment':
      case 'patch':
        return Icons.healing_rounded;
      case 'inhaler':
        return Icons.air_rounded;
      case 'capsule':
      case 'tablet':
      default:
        return Icons.medication_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = width ?? (isElder ? 64.0 : 46.0);
    final h = w;
    final displayColor = Theme.of(context).brightness == Brightness.dark
        ? Color.lerp(color, AppTheme.darkTextPrimary, 0.35)!
        : color;
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: displayColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(isElder ? 18 : 14),
        border: Border.all(color: displayColor.withValues(alpha: 0.3)),
      ),
      child: Icon(_formIcon, color: displayColor, size: isElder ? 32 : 23),
    );
  }
}
