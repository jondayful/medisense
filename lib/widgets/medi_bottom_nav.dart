import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../providers/app_state_provider.dart';
import '../theme/app_theme.dart';
import '../services/accessibility_feedback.dart';
import 'vision_voice_fab.dart';

/// A small, floating tab bar designed to stay cheap during scroll and camera
/// updates. Icons are const IconData glyphs, and tab changes only cross-fade
/// colour/background state; there are no transforms or spring layouts.
class MediBottomNav extends StatelessWidget {
  final String currentRoute;
  final bool dark;
  final bool large;
  final bool visionLoss;

  const MediBottomNav({
    super.key,
    required this.currentRoute,
    this.dark = false,
    this.large = false,
    this.visionLoss = false,
  });

  static const _baseItems = <(IconData, IconData, String, String)>[
    (CupertinoIcons.house, CupertinoIcons.house_fill, 'Home', '/'),
    (CupertinoIcons.viewfinder, CupertinoIcons.viewfinder, 'Scan', '/scan'),
    (CupertinoIcons.calendar, CupertinoIcons.calendar, 'Schedule', '/schedule'),
    (
      CupertinoIcons.gear_alt,
      CupertinoIcons.gear_alt_fill,
      'Settings',
      '/settings',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    const items = _baseItems;
    var selectedIndex = items.indexWhere((item) => item.$4 == currentRoute);
    // Guardian is intentionally a dashboard destination, not a permanent tab.
    // Leave the four main destinations unselected while that screen is open.
    if (selectedIndex < 0 && currentRoute != '/guardian') selectedIndex = 0;

    final isDarkTheme = Theme.of(context).brightness == Brightness.dark;
    final isDarkSurface = dark || isDarkTheme;
    // A live backdrop filter over the camera preview forced an extra GPU pass
    // on iPhone whenever the bar rebuilt during scanning or speech updates.
    final surfaceColor = isDarkSurface
        ? AppTheme.darkCardSurface
        : AppTheme.card;
    final capsuleBorderColor = isDarkSurface
        ? AppTheme.darkBorder
        : AppTheme.timber;
    final capsuleShadow = isDarkSurface
        ? const BoxShadow(
            color: Color.fromRGBO(0, 0, 0, 0.5),
            blurRadius: 30,
            offset: Offset(0, 8),
          )
        : const BoxShadow(
            color: Color.fromRGBO(0, 0, 0, 0.08),
            blurRadius: 24,
            offset: Offset(0, 8),
          );

    final voiceNavigationEnabled = context
        .watch<AppStateProvider>()
        .voiceNavigationEnabled;

    // Keep one bottom-bar geometry while Voice Navigation toggles. Replacing
    // the whole bar used to change Scaffold's body height mid-interaction.
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: RepaintBoundary(
        child: _VisionLossNavBar(
          items: items,
          selectedIndex: selectedIndex,
          dark: isDarkSurface,
          large: visionLoss || large,
          showMic: voiceNavigationEnabled,
          materialColor: surfaceColor,
          borderColor: capsuleBorderColor,
          shadow: capsuleShadow,
          onNavigate: (route) => context.go(route),
        ),
      ),
    );
  }
}

class _VisionLossNavBar extends StatelessWidget {
  final List<(IconData, IconData, String, String)> items;
  final int selectedIndex;
  final bool dark;
  final bool large;
  final bool showMic;
  final Color materialColor;
  final Color borderColor;
  final BoxShadow shadow;
  final ValueChanged<String> onNavigate;

  const _VisionLossNavBar({
    required this.items,
    required this.selectedIndex,
    required this.dark,
    required this.large,
    required this.showMic,
    required this.materialColor,
    required this.borderColor,
    required this.shadow,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context) {
    // The raised mic has a stable 72dp target. Standard mode keeps its normal
    // 60dp capsule underneath it; the mic simply overlaps the capsule rather
    // than increasing that capsule's height.
    final capsuleHeight = large ? 72.0 : 60.0;
    // Reserve room above the capsule so the 72dp button can float without
    // being clipped. This does not alter the capsule's own height.
    const dockHeight = 92.0;
    return SizedBox(
      height: dockHeight,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: capsuleHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: borderColor, width: 1),
                borderRadius: BorderRadius.circular(34),
                boxShadow: [shadow],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(34),
                child: ColoredBox(
                  color: materialColor,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final hasGuardian = items.length > 4;
                      final leftCount = hasGuardian ? 2 : items.length ~/ 2;
                      final centerGap = !showMic
                          ? 0.0
                          : hasGuardian
                          ? (constraints.maxWidth * 0.18)
                                .clamp(52.0, 68.0)
                                .toDouble()
                          : 72.0;

                      return Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                for (var i = 0; i < leftCount; i++)
                                  Expanded(
                                    child: _item(
                                      context,
                                      items[i],
                                      i,
                                      compactLabel: true,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          SizedBox(width: centerGap),
                          Expanded(
                            child: Row(
                              children: [
                                for (var i = leftCount; i < items.length; i++)
                                  Expanded(
                                    child: _item(
                                      context,
                                      items[i],
                                      i,
                                      compactLabel: true,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          if (showMic)
            const Positioned(top: 0, child: VisionVoiceFab(embedded: true)),
        ],
      ),
    );
  }

  Widget _item(
    BuildContext context,
    (IconData, IconData, String, String) item,
    int index, {
    bool compactLabel = false,
  }) {
    return _NavItem(
      inactiveIcon: item.$1,
      activeIcon: item.$2,
      label: item.$3,
      selected: index == selectedIndex,
      large: large,
      dark: dark,
      compactLabel: compactLabel,
      onTap: () => onNavigate(item.$4),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData inactiveIcon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final bool large;
  final bool dark;
  final bool compactLabel;
  final VoidCallback onTap;

  const _NavItem({
    required this.inactiveIcon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.large,
    required this.dark,
    this.compactLabel = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final active = dark ? AppTheme.darkSuccess : AppTheme.primaryDark;
    final inactive = dark ? AppTheme.darkTextSecondary : AppTheme.mutedText;
    final activeLabel = active;
    final activeGlyph = active;
    final highlight = active.withValues(alpha: large ? 0.20 : 0.12);

    return Semantics(
      container: true,
      button: true,
      inMutuallyExclusiveGroup: true,
      selected: selected,
      label: '$label tab',
      child: InkWell(
        onTap: () {
          AccessibilityFeedback.selection();
          onTap();
        },
        borderRadius: BorderRadius.circular(24),
        child: SizedBox(
          height: large ? 78 : 56,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                curve: Curves.linear,
                padding: EdgeInsets.symmetric(
                  horizontal: large ? 10 : 8,
                  vertical: large ? 5 : 2,
                ),
                decoration: BoxDecoration(
                  color: selected ? highlight : Colors.transparent,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Icon(
                  selected ? activeIcon : inactiveIcon,
                  size: large ? 30 : 22,
                  color: selected ? activeGlyph : inactive,
                ),
              ),
              const SizedBox(height: 2),
              SizedBox(
                width: double.infinity,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: AppTheme.textStyle(
                      fontSize: compactLabel
                          ? (large ? 11 : 9.5)
                          : (large ? 13 : 11),
                      fontWeight: large ? FontWeight.w700 : FontWeight.w600,
                      color: selected ? activeLabel : inactive,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
