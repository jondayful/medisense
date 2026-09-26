import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';
import '../providers/voice_navigation_provider.dart';
import '../services/accessibility_feedback.dart';
import '../theme/app_theme.dart';
import 'model_download_sheet.dart';
import 'take_confirm_sheet.dart';

/// One persistent voice control for Vision Loss mode.
///
/// It deliberately sits above the shared navigation capsule and never moves
/// between screens, so its location can be learned without sight.
class VisionVoiceFab extends StatefulWidget {
  final bool embedded;
  // Retained for hot-reload compatibility with builds that used compact mic
  // variants. The shared raised dock now intentionally uses one size.
  final bool compact;
  final bool largeCompact;

  const VisionVoiceFab({
    super.key,
    this.embedded = false,
    this.compact = false,
    this.largeCompact = false,
  });

  @override
  State<VisionVoiceFab> createState() => _VisionVoiceFabState();
}

class _VisionVoiceFabState extends State<VisionVoiceFab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  Timer? _landmarkTimer;
  VoiceNavigationProvider? _voice;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      lowerBound: 0.96,
      upperBound: 1.04,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final voice = context.read<VoiceNavigationProvider>();
    if (identical(voice, _voice)) return;
    _voice?.removeListener(_syncListening);
    _voice = voice..addListener(_syncListening);
    _syncListening();
  }

  @override
  void dispose() {
    _voice?.removeListener(_syncListening);
    _stopLandmarks();
    _pulse.dispose();
    super.dispose();
  }

  /// The pulse follows the provider, not the button press, so a session opened
  /// by the wake word animates exactly like a tapped one.
  void _syncListening() {
    if (!mounted) return;
    if (_voice?.isListening ?? false) {
      _pulse.repeat(reverse: true);
      _landmarkTimer ??= Timer.periodic(const Duration(seconds: 3), (_) {
        if (_voice?.isListening ?? false) {
          AccessibilityFeedback.listeningLandmark();
        }
      });
    } else {
      _stopLandmarks();
    }
  }

  void _stopLandmarks() {
    _landmarkTimer?.cancel();
    _landmarkTimer = null;
    _pulse.stop();
    _pulse.value = 1;
  }

  Future<void> _stopListening({bool playResolvedTone = false}) async {
    await context.read<VoiceNavigationProvider>().stopListening();
    _stopLandmarks();
    if (playResolvedTone) AccessibilityFeedback.voiceResolved();
  }

  Future<void> _toggle() async {
    final voice = context.read<VoiceNavigationProvider>();
    if (voice.isScanAnswerListening) {
      voice.extendScanAnswerListening();
      AccessibilityFeedback.selection();
      return;
    }
    if (voice.isListening) {
      AccessibilityFeedback.selection();
      await _stopListening(playResolvedTone: true);
      return;
    }
    if (_starting) return;
    if (!context.read<AppStateProvider>().voiceNavigationEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enable Voice Navigation in Settings.')),
      );
      return;
    }
    if (!voice.pushToTalkMode) voice.setPushToTalkMode(true);

    setState(() => _starting = true);
    try {
      if (!voice.isVoskInitialized) {
        final ready = await showModelDownloadSheet(context);
        if (!ready || !mounted) return;
      }
      if (!mounted) return;
      AccessibilityFeedback.voiceOpened();

      final recognized = await voice.startVoiceSession(
        duration: const Duration(seconds: 8),
      );
      if (!mounted) return;
      _stopLandmarks();
      AccessibilityFeedback.voiceResolved();
      if (recognized && voice.pendingTakeCandidates != null) {
        await showTakeConfirmSheet(context);
      } else if (recognized && voice.pendingRemovalMedication != null) {
        await showRemoveMedicationConfirmDialog(context);
      }
    } catch (error, stackTrace) {
      debugPrint('Voice microphone start failed: $error\n$stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Microphone could not start. Check your permissions and try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final voice = context.watch<VoiceNavigationProvider>();
    final active = voice.isListening;
    // Keep the spinner for heavyweight model preparation only. The command
    // session itself should show a microphone, then the listening glyph, so
    // starting TTS or a slow result callback cannot look like a frozen button.
    final busy = _starting && !voice.isVoskInitialized;
    final preparingSession = _starting && !busy && !active;
    final wakeArmed = voice.isWakeWordArmed;
    final fill = active || busy
        ? (isDark ? AppTheme.darkFoil : AppTheme.foil)
        : (isDark ? AppTheme.darkAccentGreen : AppTheme.ink);
    final foreground = isDark
        ? AppTheme.darkPrimaryForeground
        : AppTheme.primaryForeground;
    const outerSize = 72.0;
    const innerSize = 68.0;
    const iconSize = 32.0;
    const borderWidth = 3.0;

    final mic = Semantics(
      button: true,
      enabled: !_starting || active || voice.isScanAnswerListening,
      label: busy
          ? 'Loading voice assistant. Please wait.'
          : preparingSession
          ? 'Starting microphone. Wait for the listening cue.'
          : active
          ? 'Listening for command. Double-tap to stop.'
          : 'Voice assistant. Double-tap to start listening.',
      hint: busy
          ? 'Loading the offline voice listener'
          : preparingSession
          ? 'The microphone will listen after the cue'
          : active
          ? 'Stops listening'
          : wakeArmed
          ? 'Starts voice commands. You can also say hey MediSense.'
          : 'Starts voice commands for navigation and medication actions',
      child: ScaleTransition(
        scale: _pulse,
        child: SizedBox(
          width: outerSize,
          height: outerSize,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _starting && !active && !voice.isScanAnswerListening
                  ? null
                  : _toggle,
              child: Center(
                child: Container(
                  width: innerSize,
                  height: innerSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(
                        color: Color.fromRGBO(0, 0, 0, 0.28),
                        blurRadius: 10,
                        offset: Offset(0, 4),
                      ),
                    ],
                    border: Border.all(
                      color: isDark
                          ? AppTheme.darkTextPrimary
                          : AppTheme.inkText,
                      width: borderWidth,
                    ),
                  ),
                  child: Material(
                    color: fill,
                    shape: const CircleBorder(),
                    elevation: widget.embedded ? 0 : 4,
                    child: Center(
                      child: busy
                          ? SizedBox.square(
                              dimension: iconSize,
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                color: foreground,
                              ),
                            )
                          : Icon(
                              active
                                  ? Icons.graphic_eq_rounded
                                  : Icons.mic_rounded,
                              size: iconSize,
                              color: foreground,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return widget.embedded ? mic : Hero(tag: 'vision_voice_fab', child: mic);
  }
}
