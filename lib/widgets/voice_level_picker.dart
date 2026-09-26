import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Five connected, keyboard-accessible choices for voice preferences.
class VoiceLevelPicker extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  final Color accent;
  final bool large;
  final String semanticLabel;
  final String? lowLabel;
  final String? highLabel;
  // Kept for source compatibility with older callers. Preview actions now
  // belong beside each setting title.
  final VoidCallback? onTest;

  const VoiceLevelPicker({
    super.key,
    required this.value,
    required this.onChanged,
    required this.accent,
    required this.semanticLabel,
    this.lowLabel,
    this.highLabel,
    this.large = false,
    this.onTest,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final track = isDark ? AppTheme.darkMuted : AppTheme.muted;
    final inactiveText = AppTheme.primaryTextColor(context);
    final endpointText = AppTheme.secondaryTextColor(context);
    final selectedText = isDark
        ? AppTheme.darkPrimaryForeground
        : AppTheme.primaryForeground;

    return Semantics(
      label: '$semanticLabel, level $value of 5',
      child: Column(
        children: [
          Container(
            height: large ? 64 : 52,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: track,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppTheme.borderColor(context)),
            ),
            child: Row(
              children: List.generate(5, (index) {
                final level = index + 1;
                final selected = level == value;
                return Expanded(
                  child: Semantics(
                    button: true,
                    selected: selected,
                    label: '$semanticLabel level $level of 5',
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => onChanged(level),
                        borderRadius: BorderRadius.circular(14),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: selected ? accent : Colors.transparent,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            '$level',
                            style: AppTheme.textStyle(
                              color: selected ? selectedText : inactiveText,
                              fontSize: large ? 22 : 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  lowLabel ?? _defaultLowLabel,
                  style: AppTheme.textStyle(
                    color: endpointText,
                    fontSize: large ? 16 : 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  highLabel ?? _defaultHighLabel,
                  style: AppTheme.textStyle(
                    color: endpointText,
                    fontSize: large ? 16 : 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String get _defaultLowLabel {
    switch (semanticLabel) {
      case 'Talking speed':
        return 'Slow';
      case 'Voice pitch':
        return 'Low';
      default:
        return 'Quiet';
    }
  }

  String get _defaultHighLabel {
    switch (semanticLabel) {
      case 'Talking speed':
        return 'Fast';
      case 'Voice pitch':
        return 'High';
      default:
        return 'Loud';
    }
  }
}
