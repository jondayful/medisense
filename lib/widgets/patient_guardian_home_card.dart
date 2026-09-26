import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/app_theme.dart';

/// Patient-side shortcut to review guardian invitations and connections.
class PatientGuardianHomeCard extends StatelessWidget {
  final bool large;

  const PatientGuardianHomeCard({super.key, this.large = false});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = AppTheme.surfaceColor(context);
    final border = AppTheme.borderColor(context);
    final accent = AppTheme.actionColor(context);
    final primary = AppTheme.primaryTextColor(context);
    final secondary = AppTheme.secondaryTextColor(context);

    return Semantics(
      button: true,
      label:
          'Add your Guardian. Review invitations and connected guardians. A guardian can invite your account email.',
      excludeSemantics: true,
      child: Material(
        color: surface,
        elevation: isDark ? 0 : 2,
        shadowColor: Colors.black.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: border),
        ),
        child: InkWell(
          onTap: () => context.go('/guardian'),
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: large ? 24 : 18,
              vertical: large ? 22 : 18,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: large ? 64 : 52,
                      height: large ? 64 : 52,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: isDark ? 0.20 : 0.10),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Icon(
                        Icons.person_add_alt_1_rounded,
                        color: accent,
                        size: large ? 34 : 27,
                      ),
                    ),
                    SizedBox(width: large ? 16 : 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'CARE TEAM',
                            style: AppTheme.microLabel(
                              fontSize: large ? 14 : 11,
                              color: accent,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Add your Guardian',
                            softWrap: true,
                            style: AppTheme.textStyle(
                              fontSize: large ? 24 : 18,
                              height: 1.2,
                              fontWeight: FontWeight.w700,
                              color: primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: large ? 8 : 4),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: accent,
                      size: large ? 32 : 26,
                    ),
                  ],
                ),
                SizedBox(height: large ? 16 : 12),
                Text(
                  'Review invitations and connected guardians. A guardian can invite your account email.',
                  softWrap: true,
                  style: AppTheme.textStyle(
                    fontSize: large ? 19 : 14,
                    height: 1.4,
                    color: secondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
