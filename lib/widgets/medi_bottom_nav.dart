import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
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
    final useBoundedIosBlur = defaultTargetPlatform == TargetPlatform.iOS;
    final materialColor = isDarkSurface
        ? AppTheme.darkCardSurface.withValues(alpha: 0.85)
        : AppTheme.card.withValues(alpha: 0.85);
    final surfaceColor = useBoundedIosBlur || isDarkSurface
        ? materialColor
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

    // Voice Navigation always uses the same raised, centered microphone dock.
    // This gives every display mode one reliable place to start a command.
    if (voiceNavigationEnabled) {
      return SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        child: _VisionLossNavBar(
          items: items,
          selectedIndex: selectedIndex,
          dark: isDarkSurface,
          large: visionLoss || large,
          materialColor: surfaceColor,
          borderColor: capsuleBorderColor,
          shadow: capsuleShadow,
          onNavigate: (route) => context.go(route),
        ),
      );
    }

    final bar = RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: capsuleBorderColor, width: 1),
          borderRadius: BorderRadius.circular(34),
          boxShadow: [capsuleShadow],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(34),
          child: _TabBarSurface(
            color: surfaceColor,
            useBlur: useBoundedIosBlur,
            child: SizedBox(
              height: large ? 84 : 60,
              child: Row(
                children: [
                  for (var i = 0; i < items.length; i++)
                    Expanded(
                      child: _NavItem(
                        inactiveIcon: items[i].$1,
                        activeIcon: items[i].$2,
                        label: items[i].$3,
                        selected: i == selectedIndex,
                        large: large,
                        dark: isDarkSurface,
                        onTap: () => context.go(items[i].$4),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // SafeArea keeps the capsule above the home indicator. Horizontal and
    // vertical margins are fixed, so scrolling/camera frames never trigger a
    // relayout of the tab bar geometry.
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(20, 8, 20, 14),
      child: bar,
    );
  }
}

class _VisionLossNavBar extends StatelessWidget {
  final List<(IconData, IconData, String, String)> items;
  final int selectedIndex;
  final bool dark;
  final bool large;
  final Color materialColor;
  final Color borderColor;
  final BoxShadow shadow;
  final ValueChanged<String> onNavigate;

  const _VisionLossNavBar({
    required this.items,
    required this.selectedIndex,
    required this.dark,
    required this.large,
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
                child: _TabBarSurface(
                  color: materialColor,
                  useBlur: defaultTargetPlatform == TargetPlatform.iOS,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final hasGuardian = items.length > 4;
                      final leftCount = hasGuardian ? 2 : items.length ~/ 2;
                      final centerGap = hasGuardian
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

class _TabBarSurface extends StatelessWidget {
  final Color color;
  final bool useBlur;
  final Widget child;

  const _TabBarSurface({
    required this.color,
    required this.useBlur,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!useBlur) {
      return ColoredBox(color: color, child: child);
    }

    // One clipped blur region on iOS only. Android uses the same translucent
    // material colour without a live filter to protect budget GPU frame time.
    return Stack(
      fit: StackFit.expand,
      children: [
        BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: ColoredBox(color: color),
        ),
        child,
      ],
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
