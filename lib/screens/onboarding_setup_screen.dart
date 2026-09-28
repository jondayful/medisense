import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../models/accessibility_mode.dart';
import '../models/voice_levels.dart';
import '../providers/app_state_provider.dart';
import '../providers/tts_provider.dart';
import '../providers/voice_navigation_provider.dart';
import '../services/accessibility_feedback.dart';
import '../services/motion_preferences.dart';
import '../theme/app_theme.dart';
import '../widgets/mode_card.dart';
import '../widgets/model_download_sheet.dart';
import '../widgets/voice_level_picker.dart';

/// First-boot setup. Each preference is written through AppStateProvider as it
/// changes, so leaving the flow never loses the user's accessibility choices.
class OnboardingSetupScreen extends StatefulWidget {
  const OnboardingSetupScreen({super.key});

  @override
  State<OnboardingSetupScreen> createState() => _OnboardingSetupScreenState();
}

class _OnboardingSetupScreenState extends State<OnboardingSetupScreen> {
  final _nameController = TextEditingController();
  int _step = 0;
  bool _testingVoice = false;
  bool _namePromptSpoken = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _next() {
    if (_step < 4) setState(() => _step++);
  }

  void _goToName() => setState(() => _step = 4);

  /// Choosing an entry method is an action, not a tutorial-next control. Mark
  /// setup complete before leaving so a restart resumes the chosen workflow
  /// instead of dropping the person back into onboarding.
  void _startMedicineEntry(AppStateProvider appState, String route) {
    appState.completeOnboarding();
    context.go(route);
  }

  void _back() {
    if (_step == 0) return;
    setState(() => _step--);
  }

  void _finish(AppStateProvider appState) async {
    await appState.setOnboardingName(_nameController.text);
    appState.completeOnboarding();
    if (!mounted) return;
    context.go('/');
  }

  Future<void> _testVoice() async {
    final tts = context.read<TtsProvider>();
    setState(() => _testingVoice = true);
    await tts.speak(
      'This is how MediSense will read your medicine schedule.',
      'Ganito babasahin ng MediSense ang iyong iskedyul ng gamot.',
    );
    if (mounted) setState(() => _testingVoice = false);
  }

  Future<void> _practiceVoice() async {
    final voice = context.read<VoiceNavigationProvider>();
    if (!voice.isVoskInitialized) {
      final ready = await showModelDownloadSheet(context);
      if (!ready || !mounted) return;
    }
    HapticFeedback.mediumImpact();
    await voice.listenAndNavigateOnce(duration: const Duration(seconds: 8));
    final heard = voice.lastHeard;
    if (!mounted) return;
    AccessibilityFeedback.voiceResolved();
    final tts = context.read<TtsProvider>();
    final recognized =
        heard != null && VoiceNavigationProvider.isWakeWord(heard);
    await tts.speak(
      recognized
          ? 'Great. I heard Hey MediSense. You can now say a command.'
          : 'Try saying Hey MediSense clearly while the microphone is listening.',
      recognized
          ? 'Ayos. Narinig ko ang Hey MediSense. Maaari ka nang magsabi ng utos.'
          : 'Sabihin ang Hey MediSense habang nakikinig ang mikropono.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLarge = appState.accessibilityMode.usesLargeText;
    final titleSize = isLarge ? 30.0 : 26.0;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Row(
                children: [
                  if (_step > 0)
                    IconButton(
                      tooltip: 'Go back',
                      onPressed: _back,
                      icon: const Icon(Icons.arrow_back_rounded),
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                    )
                  else
                    const SizedBox(width: 48),
                  Expanded(
                    child: Text(
                      'MediSense setup',
                      textAlign: TextAlign.center,
                      style: AppTheme.textStyle(
                        fontSize: isLarge ? 22 : 18,
                        fontWeight: FontWeight.w800,
                        color: isDark
                            ? AppTheme.darkTextPrimary
                            : AppTheme.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Semantics(
                label: 'Setup step ${_step + 1} of 5',
                child: LinearProgressIndicator(
                  value: (_step + 1) / 5,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(6),
                  color: isDark ? AppTheme.darkAccentGreen : AppTheme.ink,
                  backgroundColor: isDark ? AppTheme.darkMuted : AppTheme.muted,
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
                child: AnimatedSwitcher(
                  duration: prefersReducedMotion(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  child: _buildStep(
                    appState,
                    titleSize,
                    isDark,
                    key: ValueKey(_step),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep(
    AppStateProvider appState,
    double titleSize,
    bool isDark, {
    required Key key,
  }) {
    switch (_step) {
      case 0:
        return _modeStep(appState, titleSize, key);
      case 1:
        return _voiceStep(appState, titleSize, isDark, key);
      case 2:
        return _trainingStep(appState, titleSize, key);
      case 3:
        return _scanStep(appState, titleSize, key);
      default:
        return _nameStep(appState, titleSize, key);
    }
  }

  Widget _modeStep(AppStateProvider appState, double titleSize, Key key) {
    return _Page(
      key: key,
      title: 'How would you like MediSense to look?',
      subtitle:
          'Choose an experience that feels comfortable. You can change this anytime in Settings.',
      titleSize: titleSize,
      children: [
        ...[
          AccessibilityMode.none,
          AccessibilityMode.elder,
          AccessibilityMode.visionLoss,
        ].map(
          (mode) => Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: ModeCard(
              mode: mode,
              selected: appState.accessibilityMode == mode,
              isElder: appState.accessibilityMode.usesLargeText,
              onTap: () async {
                await appState.setAccessibilityMode(mode);
                if (!mounted || !mode.isVisionLoss) return;
                await context.read<TtsProvider>().speak(
                  'Vision Loss mode selected. The microphone is in the center of the bottom bar. I will guide you through a practice command next.',
                  'Napili ang Vision Loss mode. Nasa gitna ng ibabang bar ang mikropono. Tuturuan kitang magsabi ng utos.',
                );
              },
            ),
          ),
        ),
        _primaryButton('Continue', _next),
      ],
    );
  }

  Widget _voiceStep(
    AppStateProvider appState,
    double titleSize,
    bool isDark,
    Key key,
  ) {
    final tts = context.watch<TtsProvider>();
    final secondary = isDark
        ? AppTheme.darkTextSecondary
        : AppTheme.textSecondary;
    return _Page(
      key: key,
      title: 'Audio & Voice Preferences',
      subtitle:
          'Adjust how MediSense speaks to you. You can change this anytime in Settings.',
      titleSize: titleSize,
      children: [
        _voiceLevelCard(
          label: 'Volume / Loudness',
          value: appState.ttsVolume,
          values: VoiceLevels.volume,
          leading: 'Quiet',
          trailing: 'Loud',
          onChanged: (value) {
            appState.setTtsVolume(value);
            tts.setVolume(value);
          },
          onSelected: _testVoice,
        ),
        _voiceLevelCard(
          label: 'Talking Speed',
          value: appState.ttsSpeed,
          values: VoiceLevels.speed,
          leading: 'Slow',
          trailing: 'Fast',
          onChanged: (value) {
            appState.setTtsSpeed(value);
            tts.setSpeechRate(value);
          },
        ),
        _voiceLevelCard(
          label: 'Voice Pitch',
          value: appState.ttsPitch,
          values: VoiceLevels.pitch,
          leading: 'Deeper',
          trailing: 'Higher',
          onChanged: (value) {
            appState.setTtsPitch(value);
            tts.setPitch(value);
          },
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Spoken announcements'),
          subtitle: Text(
            'Read screen titles and medicine reminders aloud',
            style: TextStyle(color: secondary),
          ),
          value: appState.ttsVerbosity != TtsVerbosity.essential,
          onChanged: (enabled) => appState.setTtsVerbosity(
            enabled ? TtsVerbosity.standard : TtsVerbosity.essential,
          ),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Voice Navigation'),
          subtitle: Text(
            'Show the microphone control for voice commands',
            style: TextStyle(color: secondary),
          ),
          value: appState.voiceNavigationEnabled,
          onChanged: appState.setVoiceNavigationEnabled,
        ),
        if (appState.voiceNavigationEnabled) _voiceDockPreview(),
        _outlineButton(
          _testingVoice ? 'Playing sample…' : 'Test Voice',
          _testingVoice ? null : _testVoice,
          icon: Icons.volume_up_rounded,
        ),
        _primaryButton('Continue', _next),
      ],
    );
  }

  Widget _scanStep(AppStateProvider appState, double titleSize, Key key) {
    final isLarge = appState.accessibilityMode.isElder;
    final isVision = appState.accessibilityMode.isVisionLoss;
    return _Page(
      key: key,
      title: 'Add Your First Medicine',
      subtitle: isLarge
          ? 'We will guide you step by step. You can scan a label or enter the medicine yourself.'
          : isVision
          ? 'You can use the center microphone for voice help while adding a medicine.'
          : 'Scan a prescription label or box now to have your schedule ready right away.',
      titleSize: titleSize,
      children: [
        _iconPanel(Icons.document_scanner_rounded),
        if (isLarge) ...[
          _commandCard('1. Hold the medicine label steady in good light.'),
          _commandCard(
            '2. Check the medicine name and strength before saving.',
          ),
          _commandCard(
            '3. Set the time and expiration month, then turn on reminders.',
          ),
        ],
        if (isVision) ...[
          _commandCard('Find the microphone in the center of the bottom bar.'),
          _commandCard('Tap it and say “Hey MediSense” to practise.'),
          _commandCard('Say “Read today’s schedule” to hear your medicines.'),
        ],
        _primaryButton(
          'Scan Medicine Now',
          () => _startMedicineEntry(appState, '/scan'),
          icon: Icons.camera_alt_rounded,
        ),
        _outlineButton(
          'Enter manually',
          () => _startMedicineEntry(appState, '/schedule'),
          icon: Icons.edit_note_rounded,
        ),
        TextButton(
          onPressed: _goToName,
          child: const Text('I’ll do this later'),
        ),
      ],
    );
  }

  Widget _trainingStep(AppStateProvider appState, double titleSize, Key key) {
    final largeText = appState.accessibilityMode.isElder;
    final voice = appState.voiceNavigationEnabled;
    return _Page(
      key: key,
      title: largeText
          ? 'Find your daily medicines'
          : voice
          ? 'Ready to use your voice?'
          : 'Your everyday medicine routine',
      subtitle: largeText
          ? 'The Schedule tab puts the current time of day first. Tap a medicine to review its details, then mark a dose taken after you take it.'
          : appState.accessibilityMode.isVisionLoss
          ? 'The center microphone is your guide. Tap it, say “Hey MediSense”, then ask for your schedule or next medicine.'
          : 'Scan a label, check the result, and set a reminder for each medicine.',
      titleSize: titleSize,
      children: [
        _iconPanel(
          voice ? Icons.mic_rounded : Icons.calendar_month_rounded,
          large: true,
        ),
        if (largeText) ...[
          _commandCard('The top section shows medicines for the current time.'),
          _commandCard('Tap a medicine to check its dose and expiry month.'),
          _commandCard('A reminder alarm will sound at its scheduled time.'),
        ],
        if (!largeText && !voice) ...[
          _commandCard('Check the medicine name and strength after a scan.'),
          _commandCard('Set a reminder time and expiration month.'),
          _commandCard('Open Schedule to see what is due now.'),
        ],
        if (voice) ...[
          for (final command in [
            'What is my next medicine?',
            'Mark Biogesic as taken',
            'Read today’s schedule',
            'Where am I?',
          ])
            _commandCard(command),
          _outlineButton(
            'Practise: Hey MediSense',
            _practiceVoice,
            icon: Icons.mic_rounded,
          ),
        ],
        _primaryButton('Continue', _next),
      ],
    );
  }

  Widget _nameStep(AppStateProvider appState, double titleSize, Key key) {
    final isVision = appState.accessibilityMode.isVisionLoss;
    if (isVision && appState.voiceNavigationEnabled && !_namePromptSpoken) {
      _namePromptSpoken = true;
      // The spoken prompt is deliberately scheduled after the first frame so
      // it never fires while the previous step is still animating.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context.read<TtsProvider>().speak(
            'What should we call you? Type or speak your name.',
            'Ano ang itatawag namin sa iyo? I-type o sabihin ang iyong pangalan.',
          );
        }
      });
    }
    return _Page(
      key: key,
      title: 'What should we call you?',
      subtitle: 'This name will appear in your MediSense greeting.',
      titleSize: titleSize,
      children: [
        TextField(
          controller: _nameController,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          style: AppTheme.textStyle(
            fontSize: appState.accessibilityMode.usesLargeText ? 22 : 18,
            fontWeight: FontWeight.w700,
          ),
          decoration: InputDecoration(
            // Short, two-line-safe copy prevents the accessibility font from
            // reducing the field hint to an unhelpful ellipsis.
            hintText: 'Name or nickname',
            hintMaxLines: 2,
            prefixIcon: const Icon(Icons.person_outline_rounded),
            filled: true,
            fillColor: isVision
                ? (Theme.of(context).brightness == Brightness.dark
                      ? AppTheme.darkInputSurface
                      : AppTheme.muted)
                : null,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                color: AppTheme.borderColor(context),
                width: 1.5,
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                color: AppTheme.borderColor(context),
                width: 1.5,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                color: Theme.of(context).brightness == Brightness.dark
                    ? AppTheme.darkAccentGreen
                    : AppTheme.ink,
                width: 2,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
          ),
        ),
        _primaryButton('Get Started', () => _finish(appState)),
      ],
    );
  }

  Widget _voiceLevelCard({
    required String label,
    required double value,
    required List<double> values,
    required String leading,
    required String trailing,
    required ValueChanged<double> onChanged,
    VoidCallback? onSelected,
  }) {
    final large = context
        .read<AppStateProvider>()
        .accessibilityMode
        .usesLargeText;
    final level = VoiceLevels.levelFor(value, values);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, large ? 16 : 12, 16, large ? 16 : 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: large ? 21 : 17,
              ),
            ),
            SizedBox(height: large ? 12 : 8),
            VoiceLevelPicker(
              value: level,
              accent: Theme.of(context).brightness == Brightness.dark
                  ? AppTheme.darkAccentGreen
                  : AppTheme.ink,
              large: large,
              semanticLabel: label,
              lowLabel: leading,
              highLabel: trailing,
              onChanged: (selectedLevel) {
                onChanged(VoiceLevels.valueFor(selectedLevel, values));
                onSelected?.call();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _voiceDockPreview() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? AppTheme.darkAccentGreen : AppTheme.ink;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCardSurface : AppTheme.muted,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          const Icon(Icons.home_outlined),
          const Spacer(),
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            child: const Icon(Icons.mic_rounded, color: Colors.white, size: 30),
          ),
          const Spacer(),
          const Icon(Icons.settings_outlined),
        ],
      ),
    );
  }

  Widget _iconPanel(IconData icon, {bool large = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Container(
        width: large ? 112 : 88,
        height: large ? 112 : 88,
        margin: const EdgeInsets.only(bottom: 20),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkCardSurface : AppTheme.muted,
          shape: BoxShape.circle,
          border: Border.all(
            color: isDark ? AppTheme.darkBorder : AppTheme.timber,
            width: 1.5,
          ),
        ),
        child: Icon(
          icon,
          size: large ? 60 : 44,
          color: isDark ? AppTheme.darkAccentGreen : AppTheme.ink,
        ),
      ),
    );
  }

  Widget _commandCard(String command) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: const Icon(Icons.record_voice_over_rounded),
        title: Text(command),
      ),
    );
  }

  Widget _primaryButton(
    String label,
    VoidCallback onPressed, {
    IconData? icon,
  }) {
    final large = context
        .read<AppStateProvider>()
        .accessibilityMode
        .usesLargeText;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: SizedBox(
        width: double.infinity,
        height: large ? 68 : 56,
        child: FilledButton.icon(
          onPressed: onPressed,
          icon: icon == null ? const SizedBox.shrink() : Icon(icon),
          label: Text(label, textAlign: TextAlign.center),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).brightness == Brightness.dark
                ? AppTheme.darkAccentGreen
                : AppTheme.ink,
            foregroundColor: Theme.of(context).brightness == Brightness.dark
                ? AppTheme.darkPrimaryForeground
                : AppTheme.primaryForeground,
            textStyle: TextStyle(
              fontSize: large ? 20 : 17,
              fontWeight: FontWeight.w800,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ),
    );
  }

  Widget _outlineButton(
    String label,
    VoidCallback? onPressed, {
    IconData? icon,
  }) {
    final large = context
        .read<AppStateProvider>()
        .accessibilityMode
        .usesLargeText;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        width: double.infinity,
        height: large ? 68 : 52,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: icon == null ? const SizedBox.shrink() : Icon(icon),
          label: Text(label, textAlign: TextAlign.center),
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).brightness == Brightness.dark
                ? AppTheme.darkAccentGreen
                : AppTheme.ink,
            side: BorderSide(
              color: Theme.of(context).brightness == Brightness.dark
                  ? AppTheme.darkBorder
                  : AppTheme.timber,
              width: 1.5,
            ),
            textStyle: TextStyle(
              fontSize: large ? 19 : 16,
              fontWeight: FontWeight.w700,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  final String title;
  final String subtitle;
  final double titleSize;
  final List<Widget> children;

  const _Page({
    super.key,
    required this.title,
    required this.subtitle,
    required this.titleSize,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: AppTheme.textStyle(
            fontSize: titleSize,
            fontWeight: FontWeight.w800,
            color: isDark ? AppTheme.darkTextPrimary : AppTheme.textPrimary,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          subtitle,
          style: AppTheme.textStyle(
            fontSize: titleSize >= 30 ? 20 : 16,
            color: isDark ? AppTheme.darkTextSecondary : AppTheme.textSecondary,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 24),
        ...children,
      ],
    );
  }
}
