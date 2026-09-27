import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../models/accessibility_mode.dart';
import '../models/voice_levels.dart';
import '../providers/app_state_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/medication_provider.dart';
import '../providers/notification_provider.dart';
import '../providers/tts_provider.dart';
import '../widgets/elder_bottom_nav.dart';
import '../widgets/mode_card.dart';
import '../widgets/medi_bottom_nav.dart';
import '../widgets/voice_level_picker.dart';
import 'user_manual_screen.dart';

String _verbosityDescription(TtsVerbosity verbosity) {
  return switch (verbosity) {
    TtsVerbosity.essential => 'Critical medicine alerts and reminders only.',
    TtsVerbosity.standard => 'Screen titles, reminders, and key actions.',
    TtsVerbosity.detailed => 'Full guidance, labels, and dosage details.',
  };
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _selectMode(BuildContext context, AccessibilityMode mode) async {
    final appState = context.read<AppStateProvider>();
    await appState.setAccessibilityMode(mode);
  }

  Future<void> _toggleMedicationAlarms(BuildContext context) async {
    final appState = context.read<AppStateProvider>();
    if (!appState.notificationsEnabled) {
      final ready = await context
          .read<NotificationProvider>()
          .ensureAlarmPermissions();
      if (!context.mounted) return;
      if (!ready) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Allow notifications and exact alarms to enable medicine alarms.',
            ),
          ),
        );
        return;
      }
    }
    appState.toggleNotifications();
    await context.read<MedicationProvider>().syncMedicationAlarms();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final ttsProvider = context.watch<TtsProvider>();
    final authProvider = context.watch<AuthProvider>();
    final isElder =
        appState.accessibilityMode.isElder ||
        appState.accessibilityMode.isVisionLoss;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isElder
        ? (isDark ? AppTheme.elderDarkAction : AppTheme.elderAction)
        : (isDark ? AppTheme.darkAccentGreen : AppTheme.primaryDark);
    final primary = AppTheme.primaryTextColor(context);
    final secondary = AppTheme.secondaryTextColor(context);
    final divider = AppTheme.dividerColor(context);
    // One semantic type scale for every Settings group. Accessibility modes
    // enlarge each role together instead of allowing individual cards to
    // invent unrelated sizes.
    final rowTitleSize = isElder ? 22.0 : 16.0;
    final captionSize = isElder ? 17.0 : 14.0;
    final valueSize = isElder ? 17.0 : 14.0;
    final rowIconSize = isElder ? 28.0 : 24.0;
    final tilePadding = EdgeInsets.symmetric(
      horizontal: 16,
      vertical: isElder ? 8 : 2,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'MediSense',
          style: AppTheme.textStyle(
            fontSize: isElder ? 28 : 22,
            fontWeight: FontWeight.w800,
            color: primary,
          ),
        ),
        systemOverlayStyle: isDark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        // Give large-text mode a little more vertical breathing room so the
        // title never sits beneath a camera cut-out or status bar.
        toolbarHeight: isElder ? 76 : null,
      ),
      // Settings is a primary destination on mobile; keep it in the dock
      // instead of hiding it behind a hamburger menu.
      body: ListView(
        // Leave the final preference row clear of the floating capsule.
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
        children: [
          _SectionHeader(title: 'Account', isElder: isElder),
          const SizedBox(height: 12),
          _AccountCard(auth: authProvider, isElder: isElder),
          const SizedBox(height: 28),
          _SectionHeader(title: 'Display Mode', isElder: isElder),
          const SizedBox(height: 12),
          ...const [
            AccessibilityMode.elder,
            AccessibilityMode.visionLoss,
            AccessibilityMode.none,
          ].map(
            (mode) => Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: ModeCard(
                mode: mode,
                isElder: isElder,
                selected: appState.accessibilityMode == mode,
                onTap: () => _selectMode(context, mode),
              ),
            ),
          ),
          const SizedBox(height: 14),
          _SectionHeader(title: 'Preferences', isElder: isElder),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: tilePadding,
                  title: Text(
                    'Filipino Language',
                    style: AppTheme.textStyle(
                      fontSize: rowTitleSize,
                      fontWeight: FontWeight.w700,
                      color: primary,
                    ),
                  ),
                  subtitle: Text(
                    ttsProvider.language == AppLanguage.filipino
                        ? 'Naka-set sa Tagalog'
                        : 'Set to English',
                    style: AppTheme.textStyle(
                      fontSize: captionSize,
                      color: secondary,
                      height: 1.3,
                    ),
                  ),
                  secondary: Icon(
                    Icons.language_rounded,
                    color: accent,
                    size: rowIconSize,
                  ),
                  value: ttsProvider.language == AppLanguage.filipino,
                  onChanged: (val) {
                    ttsProvider.setLanguage(
                      val ? AppLanguage.filipino : AppLanguage.english,
                    );
                    appState.toggleLanguage();
                  },
                  activeTrackColor: accent,
                ),
                Divider(height: 1, indent: 16, endIndent: 16, color: divider),
                SwitchListTile(
                  contentPadding: tilePadding,
                  title: Text(
                    'Medication alarms',
                    style: AppTheme.textStyle(
                      fontSize: rowTitleSize,
                      fontWeight: FontWeight.w700,
                      color: primary,
                    ),
                  ),
                  subtitle: Text(
                    'Ring at dose times and show alarm controls',
                    style: AppTheme.textStyle(
                      fontSize: captionSize,
                      color: secondary,
                      height: 1.3,
                    ),
                  ),
                  secondary: Icon(
                    Icons.notifications_rounded,
                    color: accent,
                    size: rowIconSize,
                  ),
                  value: appState.notificationsEnabled,
                  onChanged: (_) {
                    _toggleMedicationAlarms(context);
                  },
                  activeTrackColor: accent,
                ),
                Divider(height: 1, indent: 16, endIndent: 16, color: divider),
                SwitchListTile(
                  contentPadding: tilePadding,
                  title: Text(
                    'Dark Mode',
                    style: AppTheme.textStyle(
                      fontSize: rowTitleSize,
                      fontWeight: FontWeight.w700,
                      color: primary,
                    ),
                  ),
                  subtitle: Text(
                    'Use dark color scheme',
                    style: AppTheme.textStyle(
                      fontSize: captionSize,
                      color: secondary,
                      height: 1.3,
                    ),
                  ),
                  secondary: Icon(
                    Icons.dark_mode_rounded,
                    color: accent,
                    size: rowIconSize,
                  ),
                  value: appState.darkMode,
                  onChanged: (_) => appState.toggleDarkMode(),
                  activeTrackColor: accent,
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          _SectionHeader(title: 'Voice Settings', isElder: isElder),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Voice Navigation',
                      style: AppTheme.textStyle(
                        fontSize: rowTitleSize,
                        fontWeight: FontWeight.w700,
                        color: primary,
                      ),
                    ),
                    subtitle: Text(
                      isElder
                          ? appState.voiceNavigationEnabled
                                ? 'Optional: press the mic button to navigate by voice'
                                : 'Optional voice commands. Off by default in Elder mode'
                          : appState.voiceNavigationEnabled
                          ? 'Press the mic button to navigate by voice'
                          : 'Show a mic button for voice commands',
                      style: AppTheme.textStyle(
                        fontSize: captionSize,
                        height: 1.3,
                        color: secondary,
                      ),
                    ),
                    secondary: Icon(
                      Icons.mic_rounded,
                      color: accent,
                      size: rowIconSize,
                    ),
                    value: appState.voiceNavigationEnabled,
                    onChanged: appState.setVoiceNavigationEnabled,
                    activeTrackColor: accent,
                  ),
                  Divider(height: 24, color: divider),
                  _VoiceSettingHeader(
                    icon: Icons.volume_up_rounded,
                    title: 'Volume / Loudness',
                    iconSize: rowIconSize,
                    titleSize: rowTitleSize,
                    accent: accent,
                    onTest: () => ttsProvider.speak(
                      'This is your selected loudness.',
                      'Ito ang napili mong lakas ng boses.',
                    ),
                  ),
                  VoiceLevelPicker(
                    value: VoiceLevels.levelFor(
                      appState.ttsVolume,
                      VoiceLevels.volume,
                    ),
                    accent: accent,
                    large: isElder,
                    semanticLabel: 'Volume',
                    onChanged: (level) {
                      final value = VoiceLevels.valueFor(
                        level,
                        VoiceLevels.volume,
                      );
                      appState.setTtsVolume(value);
                      ttsProvider.setVolume(value);
                    },
                  ),
                  Center(
                    child: Text(
                      'Level ${VoiceLevels.levelFor(appState.ttsVolume, VoiceLevels.volume)} · '
                      '${(appState.ttsVolume * 100).round()}% loudness',
                      style: AppTheme.textStyle(
                        fontSize: valueSize,
                        color: secondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Divider(height: 24, color: divider),
                  _VoiceSettingHeader(
                    icon: Icons.speed_rounded,
                    title: 'TTS Speed',
                    iconSize: rowIconSize,
                    titleSize: rowTitleSize,
                    accent: accent,
                    onTest: () => ttsProvider.speak(
                      'This is your selected speaking speed.',
                      'Ito ang napili mong bilis ng pagsasalita.',
                    ),
                  ),
                  const SizedBox(height: 4),
                  VoiceLevelPicker(
                    value: VoiceLevels.levelFor(
                      appState.ttsSpeed,
                      VoiceLevels.speed,
                    ),
                    accent: accent,
                    large: isElder,
                    semanticLabel: 'Talking speed',
                    onChanged: (level) {
                      final value = VoiceLevels.valueFor(
                        level,
                        VoiceLevels.speed,
                      );
                      appState.setTtsSpeed(value);
                      ttsProvider.setSpeechRate(value);
                    },
                  ),
                  Center(
                    child: Text(
                      'Level ${VoiceLevels.levelFor(appState.ttsSpeed, VoiceLevels.speed)} · '
                      '${appState.ttsSpeed.toStringAsFixed(1)}x speed',
                      style: AppTheme.textStyle(
                        fontSize: valueSize,
                        color: secondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Divider(height: 24, color: divider),
                  _VoiceSettingHeader(
                    icon: Icons.graphic_eq_rounded,
                    title: 'TTS Pitch',
                    iconSize: rowIconSize,
                    titleSize: rowTitleSize,
                    accent: accent,
                    onTest: () => ttsProvider.speak(
                      'This is your selected voice pitch.',
                      'Ito ang napili mong tono ng boses.',
                    ),
                  ),
                  const SizedBox(height: 4),
                  VoiceLevelPicker(
                    value: VoiceLevels.levelFor(
                      appState.ttsPitch,
                      VoiceLevels.pitch,
                    ),
                    accent: accent,
                    large: isElder,
                    semanticLabel: 'Voice pitch',
                    onChanged: (level) {
                      final value = VoiceLevels.valueFor(
                        level,
                        VoiceLevels.pitch,
                      );
                      appState.setTtsPitch(value);
                      ttsProvider.setPitch(value);
                    },
                  ),
                  Center(
                    child: Text(
                      'Level ${VoiceLevels.levelFor(appState.ttsPitch, VoiceLevels.pitch)} · '
                      '${appState.ttsPitch.toStringAsFixed(1)}x pitch',
                      style: AppTheme.textStyle(
                        fontSize: valueSize,
                        color: secondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Divider(height: 24, color: divider),
                  Text(
                    'Announcements',
                    style: AppTheme.textStyle(
                      fontSize: rowTitleSize,
                      fontWeight: FontWeight.w700,
                      color: primary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _AnnouncementOptions(
                    selected: appState.ttsVerbosity,
                    onChanged: (verbosity) {
                      appState.setTtsVerbosity(verbosity);
                      final sample = switch (verbosity) {
                        TtsVerbosity.essential => (
                          'Essential. Medicine alarms and urgent reminders only.',
                          'Essential. Mga alarm at mahalagang paalala lamang.',
                        ),
                        TtsVerbosity.standard => (
                          'Standard. I will also announce screen names and key actions.',
                          'Standard. Sasabihin ko rin ang mga pangalan ng pahina at mahahalagang kilos.',
                        ),
                        TtsVerbosity.detailed => (
                          'Detailed. I will describe screens, controls, medicine strength, and helpful next steps.',
                          'Detailed. Ilalarawan ko ang mga pahina, pindutan, dose, at susunod na hakbang.',
                        ),
                      };
                      ttsProvider.speak(sample.$1, sample.$2);
                    },
                    accent: accent,
                    large: isElder,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),
          _SectionHeader(title: 'About', isElder: isElder),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  contentPadding: tilePadding,
                  minVerticalPadding: isElder ? 14 : 8,
                  leading: Icon(
                    Icons.menu_book_rounded,
                    color: accent,
                    size: rowIconSize,
                  ),
                  title: Text(
                    'User Manual',
                    style: AppTheme.textStyle(
                      fontSize: rowTitleSize,
                      fontWeight: FontWeight.w700,
                      color: primary,
                    ),
                  ),
                  subtitle: Text(
                    'Learn scanning, schedules, reminders, and voice commands',
                    style: AppTheme.textStyle(
                      fontSize: captionSize,
                      color: secondary,
                      height: 1.3,
                    ),
                  ),
                  trailing: Icon(Icons.chevron_right, color: secondary),
                  // Use a local page push so this newly added Settings entry
                  // also works after hot reload, when GoRouter may still hold
                  // the route table created before /user-manual existed.
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const UserManualScreen(),
                      settings: const RouteSettings(name: '/user-manual'),
                    ),
                  ),
                ),
                Divider(height: 1, indent: 16, endIndent: 16, color: divider),
                _VersionCheckTile(
                  contentPadding: tilePadding,
                  isElder: isElder,
                  accent: accent,
                  primary: primary,
                  secondary: secondary,
                  rowTitleSize: rowTitleSize,
                  valueSize: valueSize,
                  rowIconSize: rowIconSize,
                ),
                Divider(height: 1, indent: 16, endIndent: 16, color: divider),
                ListTile(
                  contentPadding: tilePadding,
                  minVerticalPadding: isElder ? 14 : 8,
                  leading: Icon(
                    Icons.description_rounded,
                    color: accent,
                    size: rowIconSize,
                  ),
                  title: Text(
                    'Terms of Service',
                    style: AppTheme.textStyle(
                      fontSize: rowTitleSize,
                      fontWeight: FontWeight.w700,
                      color: primary,
                    ),
                  ),
                  trailing: Icon(Icons.chevron_right_rounded, color: secondary),
                  onTap: () => context.push('/terms'),
                ),
                Divider(height: 1, indent: 16, endIndent: 16, color: divider),
                ListTile(
                  contentPadding: tilePadding,
                  minVerticalPadding: isElder ? 14 : 8,
                  leading: Icon(
                    Icons.privacy_tip_rounded,
                    color: accent,
                    size: rowIconSize,
                  ),
                  title: Text(
                    'Privacy Policy',
                    style: AppTheme.textStyle(
                      fontSize: rowTitleSize,
                      fontWeight: FontWeight.w700,
                      color: primary,
                    ),
                  ),
                  trailing: Icon(Icons.chevron_right_rounded, color: secondary),
                  onTap: () => context.push('/privacy'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
      bottomNavigationBar: isElder
          ? ElderBottomNav(
              currentRoute: '/settings',
              visionLoss: appState.accessibilityMode.isVisionLoss,
            )
          : const MediBottomNav(currentRoute: '/settings'),
    );
  }
}

class _VoiceSettingHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final double iconSize;
  final double titleSize;
  final Color accent;
  final VoidCallback onTest;

  const _VoiceSettingHeader({
    required this.icon,
    required this.title,
    required this.iconSize,
    required this.titleSize,
    required this.accent,
    required this.onTest,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: accent, size: iconSize),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            style: AppTheme.textStyle(
              fontSize: titleSize,
              fontWeight: FontWeight.w700,
              color: AppTheme.primaryTextColor(context),
            ),
          ),
        ),
        Semantics(
          button: true,
          label: 'Test $title audio',
          child: IconButton(
            onPressed: onTest,
            tooltip: 'Test audio',
            icon: const Icon(Icons.play_arrow_rounded),
            color: accent,
            style: IconButton.styleFrom(
              backgroundColor: accent.withValues(alpha: 0.12),
              minimumSize: const Size(48, 48),
            ),
          ),
        ),
      ],
    );
  }
}

class _VersionCheckTile extends StatefulWidget {
  const _VersionCheckTile({
    required this.contentPadding,
    required this.isElder,
    required this.accent,
    required this.primary,
    required this.secondary,
    required this.rowTitleSize,
    required this.valueSize,
    required this.rowIconSize,
  });

  final EdgeInsets contentPadding;
  final bool isElder;
  final Color accent;
  final Color primary;
  final Color secondary;
  final double rowTitleSize;
  final double valueSize;
  final double rowIconSize;

  @override
  State<_VersionCheckTile> createState() => _VersionCheckTileState();
}

class _VersionCheckTileState extends State<_VersionCheckTile> {
  bool _checking = false;
  bool _checked = false;

  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _checked = false;
    });
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (mounted) {
      setState(() {
        _checking = false;
        _checked = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: widget.contentPadding,
    minVerticalPadding: widget.isElder ? 14 : 8,
    leading: Icon(
      Icons.info_rounded,
      color: widget.accent,
      size: widget.rowIconSize,
    ),
    title: Text(
      'Version',
      style: AppTheme.textStyle(
        fontSize: widget.rowTitleSize,
        fontWeight: FontWeight.w700,
        color: widget.primary,
      ),
    ),
    subtitle: _checked
        ? const Text("You're on the latest version")
        : const Text('Tap to check for updates'),
    trailing: _checking
        ? const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          )
        : Text(
            '1.0.0',
            style: AppTheme.textStyle(
              fontSize: widget.valueSize,
              fontWeight: FontWeight.w600,
              color: widget.secondary,
            ),
          ),
    onTap: _check,
  );
}

/// A roomy, one-choice-per-row announcement selector. A segmented control is
/// too narrow for the large-text mode and forces labels to wrap mid-word.
class _AnnouncementOptions extends StatelessWidget {
  final TtsVerbosity selected;
  final ValueChanged<TtsVerbosity> onChanged;
  final Color accent;
  final bool large;

  const _AnnouncementOptions({
    required this.selected,
    required this.onChanged,
    required this.accent,
    required this.large,
  });

  @override
  Widget build(BuildContext context) {
    final border = AppTheme.dividerColor(context);
    final textColor = AppTheme.primaryTextColor(context);
    final surface = Theme.of(context).brightness == Brightness.dark
        ? AppTheme.darkMuted
        : AppTheme.muted;

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
      ),
      child: Column(
        children: [
          for (final verbosity in TtsVerbosity.values) ...[
            if (verbosity != TtsVerbosity.values.first)
              Divider(
                height: 1,
                indent: large ? 14 : 10,
                endIndent: large ? 14 : 10,
                color: border,
              ),
            _AnnouncementOption(
              verbosity: verbosity,
              selected: verbosity == selected,
              onTap: () => onChanged(verbosity),
              accent: accent,
              border: border,
              textColor: textColor,
              large: large,
            ),
          ],
        ],
      ),
    );
  }
}

class _AnnouncementOption extends StatelessWidget {
  final TtsVerbosity verbosity;
  final bool selected;
  final VoidCallback onTap;
  final Color accent;
  final Color border;
  final Color textColor;
  final bool large;

  const _AnnouncementOption({
    required this.verbosity,
    required this.selected,
    required this.onTap,
    required this.accent,
    required this.border,
    required this.textColor,
    required this.large,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label:
          '${verbosity.label}: ${_verbosityDescription(verbosity)}${selected ? ', selected' : ''}',
      child: Material(
        color: selected ? accent.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            constraints: BoxConstraints(minHeight: large ? 68 : 56),
            padding: EdgeInsets.symmetric(
              horizontal: large ? 18 : 16,
              vertical: large ? 12 : 10,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected ? accent : Colors.transparent,
                width: 2,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected
                      ? accent
                      : AppTheme.secondaryTextColor(context),
                  size: large ? 30 : 24,
                ),
                SizedBox(width: large ? 14 : 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        verbosity.label,
                        style: AppTheme.textStyle(
                          fontSize: large ? 20 : 16,
                          fontWeight: FontWeight.w800,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _verbosityDescription(verbosity),
                        style: AppTheme.textStyle(
                          fontSize: large ? 16 : 13,
                          color: AppTheme.secondaryTextColor(context),
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Icon(
                    Icons.check_rounded,
                    color: accent,
                    size: large ? 28 : 22,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final bool isElder;
  const _SectionHeader({required this.title, required this.isElder});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: AppTheme.textStyle(
        fontSize: isElder ? 30 : 24,
        fontWeight: FontWeight.w800,
        color: AppTheme.primaryTextColor(context),
      ),
    );
  }
}

/// Elder-only account entry: login/register when signed out, profile when
/// signed in — the drawer's account tile, but big and one-hand friendly.
class _AccountCard extends StatelessWidget {
  final AuthProvider auth;
  final bool isElder;
  const _AccountCard({required this.auth, required this.isElder});

  @override
  Widget build(BuildContext context) {
    final card = AppTheme.surfaceColor(context);
    final ink = AppTheme.primaryTextColor(context);
    final muted = AppTheme.secondaryTextColor(context);
    final accent = AppTheme.actionColor(context);
    final loggedIn = auth.isLoggedIn;

    return Material(
      color: card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: AppTheme.borderColor(context)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(loggedIn ? '/profile' : '/auth'),
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: EdgeInsets.all(isElder ? 20 : 16),
          child: Row(
            children: [
              Container(
                width: isElder ? 64 : 52,
                height: isElder ? 64 : 52,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.person_rounded,
                  color: accent,
                  size: isElder ? 36 : 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loggedIn ? auth.userName : 'Guest User',
                      maxLines: 2,
                      softWrap: true,
                      overflow: TextOverflow.visible,
                      style: AppTheme.textStyle(
                        fontSize: isElder ? 24 : 18,
                        fontWeight: FontWeight.w800,
                        color: ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      loggedIn
                          ? '${auth.tier} · ${auth.isGuardian ? 'Guardian' : 'Patient'}'
                          : 'Login or register',
                      style: AppTheme.textStyle(
                        fontSize: isElder ? 18 : 13,
                        fontWeight: FontWeight.w600,
                        color: muted,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: muted,
                size: isElder ? 32 : 24,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
