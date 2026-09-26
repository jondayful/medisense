import 'package:flutter/material.dart';
import '../models/accessibility_mode.dart';
import '../theme/app_theme.dart';
import '../services/accessibility_feedback.dart';

/// A tappable accessibility-mode choice. Shared by onboarding and Settings so
/// both places render identically, are dark-mode safe, and stay big in elder
/// mode. `selected` (Settings) highlights the active mode with a check.
class ModeCard extends StatelessWidget {
  final AccessibilityMode mode;
  final VoidCallback onTap;
  final bool selected;
  final bool isElder;

  const ModeCard({
    super.key,
    required this.mode,
    required this.onTap,
    this.selected = false,
    this.isElder = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final Color accent;
    final Color onAccent;
    switch (mode) {
      case AccessibilityMode.elder:
        accent = isDark ? AppTheme.elderDarkInk : AppTheme.ink;
        onAccent = isDark
            ? AppTheme.darkPrimaryForeground
            : AppTheme.primaryForeground;
      case AccessibilityMode.visionLoss:
        accent = isDark ? AppTheme.darkFoil : AppTheme.foil;
        onAccent = isDark ? AppTheme.darkPrimaryForeground : AppTheme.inkText;
      case AccessibilityMode.none:
        accent = isDark ? AppTheme.elderDarkDone : AppTheme.mint;
        onAccent = isDark
            ? AppTheme.darkPrimaryForeground
            : AppTheme.primaryForeground;
    }
    final accentSoft = accent.withValues(
      alpha: mode == AccessibilityMode.elder ? 0.07 : 0.12,
    );
    final activeColor = isDark ? AppTheme.darkAccentGreen : AppTheme.ink;
    final inactiveBorder = isDark ? AppTheme.darkBorder : AppTheme.timber;
    final title = AppTheme.textStyle(
      fontSize: isElder ? 24 : 18,
      fontWeight: FontWeight.w800,
      color: isDark ? AppTheme.darkTextPrimary : AppTheme.textPrimary,
    );
    final subtitle = AppTheme.textStyle(
      fontSize: isElder ? 17 : 14,
      fontWeight: isElder ? FontWeight.w600 : FontWeight.w500,
      color: isDark ? AppTheme.darkTextSecondary : AppTheme.textSecondary,
      height: 1.4,
    );

    return SizedBox(
      width: double.infinity,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 96),
        child: Stack(
          children: [
            Material(
              color: isDark ? AppTheme.darkCardSurface : Colors.white,
              borderRadius: BorderRadius.circular(AppTheme.cardRadius),
              child: InkWell(
                onTap: () {
                  AccessibilityFeedback.selection();
                  onTap();
                },
                borderRadius: BorderRadius.circular(AppTheme.cardRadius),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: accentSoft,
                    borderRadius: BorderRadius.circular(AppTheme.cardRadius),
                    border: Border.all(
                      color: selected ? activeColor : inactiveBorder,
                      width: selected ? 2 : 1.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: isElder ? 64 : 52,
                        height: isElder ? 64 : 52,
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          mode.icon,
                          color: onAccent,
                          size: isElder ? 32 : 28,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(mode.label, style: title),
                            SizedBox(height: isElder ? 6 : 4),
                            Text(mode.description, style: subtitle),
                          ],
                        ),
                      ),
                      Icon(
                        selected
                            ? Icons.check_circle_rounded
                            : Icons.arrow_forward_rounded,
                        color: selected ? activeColor : accent,
                        size: isElder ? 32 : 24,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
