import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../providers/auth_provider.dart';

class AppDrawer extends StatelessWidget {
  final String currentRoute;

  const AppDrawer({super.key, required this.currentRoute});

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final brand = isDark ? AppTheme.darkAccentGreen : AppTheme.primaryDark;
    final brandOn = isDark ? AppTheme.darkPrimaryForeground : Colors.white;
    final profileSurface = isDark
        ? AppTheme.darkAccent
        : AppTheme.primaryAccent;
    final primaryText = AppTheme.primaryTextColor(context);
    final secondaryText = AppTheme.secondaryTextColor(context);
    final screenWidth = MediaQuery.sizeOf(context).width;

    return Drawer(
      width: screenWidth < 420 ? screenWidth * 0.86 : 360,
      backgroundColor: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: brand,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      Icons.medication_rounded,
                      color: brandOn,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'MediSense',
                        style: AppTheme.textStyle(
                          color: brand,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        'Version 1.0.0',
                        style: AppTheme.textStyle(
                          color: secondaryText,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 1, indent: 24, endIndent: 24),
            const SizedBox(height: 24),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  _DrawerItem(
                    icon: Icons.grid_view_rounded,
                    label: 'Dashboard',
                    route: '/',
                    currentRoute: currentRoute,
                  ),
                  _DrawerItem(
                    icon: Icons.qr_code_scanner_rounded,
                    label: 'Scan',
                    route: '/scan',
                    currentRoute: currentRoute,
                  ),
                  _DrawerItem(
                    icon: Icons.event_note_rounded,
                    label: 'Schedule',
                    route: '/schedule',
                    currentRoute: currentRoute,
                  ),
                  if (authProvider.isLoggedIn)
                    _DrawerItem(
                      icon: Icons.family_restroom_rounded,
                      label: authProvider.isGuardian ? 'Guardian' : 'Guardians',
                      route: '/guardian',
                      currentRoute: currentRoute,
                    ),
                  const SizedBox(height: 32),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'SYSTEM',
                      style: AppTheme.textStyle(
                        color: secondaryText,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _DrawerItem(
                    icon: Icons.settings_rounded,
                    label: 'Settings',
                    route: '/settings',
                    currentRoute: currentRoute,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: InkWell(
                onTap: () {
                  Navigator.of(context).pop();
                  if (authProvider.isLoggedIn) {
                    context.push('/profile');
                  } else {
                    context.push('/auth');
                  }
                },
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: profileSurface,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: brand,
                        child: Icon(
                          Icons.person_outline_rounded,
                          color: brandOn,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              authProvider.isLoggedIn
                                  ? authProvider.userName
                                  : 'Guest User',
                              style: AppTheme.textStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                                color: primaryText,
                              ),
                              maxLines: 2,
                              softWrap: true,
                            ),
                            Text(
                              authProvider.isLoggedIn
                                  ? authProvider.isGuardian
                                        ? '${authProvider.tier} - Guardian'
                                        : authProvider.tier
                                  : 'Login / Sign Up',
                              style: AppTheme.textStyle(
                                fontSize: 12,
                                color: secondaryText,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (!authProvider.isLoggedIn)
                        Icon(
                          Icons.chevron_right_rounded,
                          color: secondaryText,
                          size: 20,
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

class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String route;
  final String currentRoute;

  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.route,
    required this.currentRoute,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = currentRoute == route;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final active = AppTheme.actionColor(context);
    final onActive = AppTheme.actionForegroundColor(context);
    final iconColor = isActive
        ? onActive
        : (isDark ? AppTheme.darkTextSecondary : AppTheme.textSecondary);
    final textColor = isActive
        ? onActive
        : (isDark ? AppTheme.darkTextPrimary : AppTheme.textPrimary);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () {
          Navigator.of(context).pop();
          if (currentRoute != route) {
            context.go(route);
          }
        },
        borderRadius: BorderRadius.circular(16),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isActive ? active : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(width: 16),
              Text(
                label,
                style: AppTheme.textStyle(
                  color: textColor,
                  fontWeight: isActive ? FontWeight.bold : FontWeight.w600,
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
