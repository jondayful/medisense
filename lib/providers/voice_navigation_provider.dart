import 'dart:async';

import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../models/medication.dart';
import '../models/voice_levels.dart';
import '../services/accessibility_feedback.dart';
import '../services/medication_catalog_store.dart';
import '../services/medicine_speech_formatter.dart';
import '../services/medicine_expiry_parser.dart';
import '../services/scan_speech_parser.dart';
import '../services/vosk_command_dispatcher.dart';
import '../services/vosk_command_listener.dart';
import '../services/vosk_model_store.dart';
import '../services/voice_medication_input.dart';
import 'app_state_provider.dart';
import 'medication_provider.dart';
import 'tts_provider.dart';

/// Friendly screen names for the spoken page announcement. A route that is
/// missing here is not a bug: [VoiceNavigationProvider.announceScreen] then
/// describes live medication state instead, so a newly added screen stays
/// truthful without a second route table to maintain.
const Map<String, ({String english, String filipino})>
kVoiceScreenAnnouncements = {
  '/': (english: 'Dashboard', filipino: 'Pangunahing pahina'),
  '/scan': (english: 'Medicine scan', filipino: 'Pag-scan ng gamot'),
  '/schedule': (
    english: 'Medication schedule',
    filipino: 'Iskedyul ng mga gamot',
  ),
  '/settings': (english: 'Settings', filipino: 'Mga setting'),
  '/profile': (english: 'Your profile', filipino: 'Iyong profile'),
  '/guardian': (
    english: 'Caregiver settings',
    filipino: 'Settings ng tagapangalaga',
  ),
  '/user-manual': (english: 'User manual', filipino: 'Gabay sa paggamit'),
  '/privacy': (english: 'Privacy policy', filipino: 'Patakaran sa privacy'),
  '/terms': (english: 'Terms of use', filipino: 'Mga tuntunin sa paggamit'),
};

/// A released-once handle for a voice pause. Callers must call [release] from
/// a `finally` block: the previous integer counters could be left unbalanced by
/// a single missed call and silenced navigation for the rest of the session.
class VoicePause {
  VoicePause(this._onRelease);

  final void Function() _onRelease;
  bool _released = false;

  bool get isReleased => _released;

  void release() {
    if (_released) return;
    _released = true;
    _onRelease();
  }
}

/// One reversible action waiting for a spoken or on-screen answer. Only one
/// prompt is ever pending; it is the single slot the conversation fills in.
sealed class _VoicePrompt {
  const _VoicePrompt();
}

/// A dose, or several, the user said they took.
final class _TakePrompt extends _VoicePrompt {
  const _TakePrompt(this.doses);
  final List<({Medication med, ScheduleTime s})> doses;
}

/// A medicine removal. Confirmed on screen only: voice can dismiss it but never
/// accepts it.
final class _RemovePrompt extends _VoicePrompt {
  const _RemovePrompt(this.medication);
  final Medication medication;
}

/// "Did you mean A or B?" — set when a spoken name matched nothing exactly.
final class _ChoicePrompt extends _VoicePrompt {
  const _ChoicePrompt({required this.spoken, required this.options});
  final String spoken;
  final List<Medication> options;
}

/// A proposed dose-time change. Never applied on the final recognition alone:
/// Vosk mishears "eight" as "ate", so a spoken yes is required.
final class _MovePrompt extends _VoicePrompt {
  const _MovePrompt({required this.medication, required this.time});
  final Medication medication;
  final TimeOfDay time;
}

enum _AddStage { dose, form, expiry, frequency, time, confirm }

final class _AddPrompt extends _VoicePrompt {
  _AddPrompt(this.name);
  final String name;
  _AddStage stage = _AddStage.dose;
  String? dose;
  String? form;
  DateTime? expiry;
  String? frequency;
  TimeOfDay? time;
}

/// Outcome of matching a spoken medicine name against the schedule.
class _NameMatch {
  const _NameMatch({
    this.exact,
    this.ambiguous = const [],
    this.suggestions = const [],
  });

  /// The single unambiguous match, if there is one.
  final Medication? exact;

  /// Several medicines share this name. The user must choose.
  final List<Medication> ambiguous;

  /// Near misses, best first, for a "did you mean" prompt.
  final List<Medication> suggestions;
}

/// The single owner of offline voice navigation and guided scan answers.
class VoiceNavigationProvider extends ChangeNotifier
    with WidgetsBindingObserver {
  VoiceNavigationProvider() {
    WidgetsBinding.instance.addObserver(this);
  }

  final VoskModelStore _modelStore = VoskModelStore();
  final VoskCommandDispatcher _dispatcher = const VoskCommandDispatcher();
  VoskCommandListener? _listener;
  GoRouter? _router;
  bool _suppressNextScheduleGreeting = false;
  TtsProvider? _tts;
  MedicationProvider? _medications;
  AppStateProvider? _appState;
  bool _listening = false;
  bool _processing = false;
  bool _commandSessionActive = false;
  bool _suppressNoMatchFeedback = false;
  bool _pushToTalkMode = false;
  bool _isForeground = true;
  bool _disposed = false;
  Future<String?>? _activeScanAnswer;
  Completer<void>? _voiceInteractionIdle;
  Completer<void>? _navigationPauseReleased;
  Completer<void>? _resumeVosk;
  Future<void>? _voskInitialization;
  Future<void>? _nativeVoskLoading;
  Future<void>? _initializationGate;
  String? _lastHeard;
  String? _partialHeard;
  _VoicePrompt? _prompt;
  int _pauseCount = 0;
  int _analysisPauseCount = 0;

  /// Doses marked taken by voice this session, so "undo" can revert them. A
  /// blind user cannot reach the visual undo action.
  final List<({Medication med, ScheduleTime s})> _undoableTakes = [];
  static const int _maxUndoableTakes = 20;

  void _rememberUndoableTake(({Medication med, ScheduleTime s}) dose) {
    if (_undoableTakes.length == _maxUndoableTakes) {
      _undoableTakes.removeAt(0);
    }
    _undoableTakes.add(dose);
  }

  /// Idle wake-word polling.
  Future<void>? _wakeLoop;
  Object? _wakeToken;
  bool _wakeArmed = false;
  bool _wakeSuspended = false;
  int _continuationHops = 0;

  /// How long the microphone stays open after an answer so a follow-up needs no
  /// new tap.
  static const continuationWindow = Duration(seconds: 8);

  /// Bounded so a confused session cannot listen forever.
  static const maxContinuationHops = 2;

  /// Idle length between wake-word polls. Long enough to be cheap, short enough
  /// that the mic does not feel dead.
  static const wakeIdleTimeout = Duration(seconds: 8);
  static const wakePartialExtension = Duration(seconds: 3);

  /// Matched a spoken medicine name: unique, ambiguous, or near-miss options.
  static const _maxNameSuggestions = 3;

  VoskModelStore get voskModelStore => _modelStore;
  bool get isVoskInitialized => _listener != null;
  bool get isInitialized => isVoskInitialized;

  /// True only while a command window is open. Idle wake-word polling
  /// deliberately leaves this false so the microphone button animates when the
  /// wake word is actually heard, and not at all times.
  bool get isListening => _listening;
  bool get isScanAnswerListening =>
      _activeScanAnswer != null && _listener?.isListening == true;
  bool get isProcessing => _processing;
  bool get isCommandSessionActive => _commandSessionActive;
  bool get pushToTalkMode => _pushToTalkMode;
  bool get isNavigationPaused => _pauseCount > 0;
  String? get lastHeard => _lastHeard;
  String? get partialHeard => _partialHeard;
  double? get modelDownloadProgress => _modelStore.progress;
  String? get downloadError => _modelStore.error;
  bool get isDownloading => _modelStore.isDownloading;

  /// Idle wake-word polling is armed and waiting for the keyword.
  bool get isWakeWordArmed => _wakeArmed && _wakeLoop != null;

  /// Retained for the confirmation sheet. Null unless a take is pending.
  List<({Medication med, ScheduleTime s})>? get pendingTakeCandidates =>
      switch (_prompt) {
        _TakePrompt(:final doses) => doses,
        _ => null,
      };

  /// Retained for the removal dialog. Null unless a removal is pending.
  Medication? get pendingRemovalMedication => switch (_prompt) {
    _RemovePrompt(:final medication) => medication,
    _ => null,
  };

  void setRouter(GoRouter router) => _router = router;
  void setTtsProvider(TtsProvider tts) => _tts = tts;
  void setMedicationProvider(MedicationProvider? provider) =>
      _medications = provider;
  void setAppStateProvider(AppStateProvider provider) => _appState = provider;

  /// Delays expensive native model construction while another screen is
  /// bringing up time-sensitive hardware such as a camera preview.
  void deferVoskInitializationUntil(Future<void> ready) {
    final previous = _initializationGate;
    _initializationGate = previous == null
        ? ready
        : Future.wait([previous, ready]).then<void>((_) {});
  }

  void setPushToTalkMode(bool value) {
    if (_pushToTalkMode == value) return;
    _pushToTalkMode = value;
    if (!value) {
      unawaited(stopListening());
      disableWakeWord();
    } else if (_listener != null) {
      enableWakeWord();
    }
    notifyListeners();
  }

  Future<void> initializeVosk(String absoluteModelPath) async {
    if (_listener != null) return;
    return _voskInitialization ??= _initializeVoskWhenAvailable(
      absoluteModelPath,
    ).whenComplete(() => _voskInitialization = null);
  }

  Future<void> _initializeVoskWhenAvailable(String absoluteModelPath) async {
    await _initializationGate;
    while (_analysisPauseCount > 0) {
      await (_resumeVosk ??= Completer<void>()).future;
    }
    if (_listener != null) return;
    final listener = VoskCommandListener(
      iosLocale: () => _appState?.isFilipino == true ? 'fil-PH' : 'en-PH',
      onPartial: (text) {
        _partialHeard = text;
        notifyListeners();
      },
      onFinalText: (text) {
        _lastHeard = text;
        _partialHeard = null;
        notifyListeners();
      },
      onCommand: _handleCommand,
      dispatcher: _dispatcher,
    );
    try {
      final loading = listener.initialize(absoluteModelPath);
      _nativeVoskLoading = loading;
      await loading;
      if (_disposed) {
        listener.detach();
        return;
      }
      _listener = listener;
      notifyListeners();
      // Voice navigation enabled but the model only just arrived: start polling.
      if (_pushToTalkMode && _isForeground) enableWakeWord();
    } catch (_) {
      await listener.dispose();
      rethrow;
    } finally {
      _nativeVoskLoading = null;
    }
  }

  // ---------------------------------------------------------------- sessions

  bool get _canListen =>
      !_disposed && _isForeground && _pushToTalkMode && _pauseCount == 0;

  /// Opens one command window. Shared by the tap button and the wake word so
  /// both behave identically.
  Future<bool> listenAndNavigateOnce({
    Duration duration = const Duration(seconds: 8),
  }) async {
    if (_commandSessionActive || _activeScanAnswer != null) return false;
    if (_disposed || !_isForeground || !_pushToTalkMode) return false;
    // Camera OCR holds a short navigation pause while it captures and reads
    // an image. A dock-mic tap during that interval should queue behind the
    // scan, not silently look unresponsive.
    await _waitForNavigationResume();
    if (!_canListen) return false;
    final listener = _listener;
    if (listener == null) throw StateError('Offline voice is not ready.');

    // A tap takes priority over idle wake polling.
    final resumeWake = await _suspendWakeWord();
    try {
      return await _runCommandWindow(listener, duration);
    } finally {
      if (resumeWake) _releaseWakeWord();
    }
  }

  Future<bool> startVoiceSession({
    Duration duration = const Duration(seconds: 8),
  }) => listenAndNavigateOnce(duration: duration);

  /// Speaks the prompt, then opens the microphone for a bounded follow-up
  /// window so "next", "repeat", "yes" and "undo" need no new tap.
  Future<bool> _runCommandWindow(
    VoskCommandListener listener,
    Duration duration,
  ) async {
    if (_commandSessionActive) return false;
    _commandSessionActive = true;
    _processing = true;
    notifyListeners();
    try {
      await listener.ensureMicrophonePermission();
      await _tts?.stop();
      _suppressNoMatchFeedback = false;
      _lastHeard = null;
      _partialHeard = null;
      // Finish the cue before AudioRecord starts so Vosk cannot recognize the
      // app's own voice. speakCue preserves the user's repeat-last message.
      await _tts?.speakCue(
        _prompt is _AddPrompt
            ? 'I am listening for the medicine detail.'
            : 'I am listening. What can I help with?',
        _prompt is _AddPrompt
            ? 'Nakikinig ako sa detalye ng gamot.'
            : 'Nakikinig na. Ano iyon?',
      );
      // Some Android TTS engines report completion just before releasing
      // audio focus. This keeps the first spoken syllable from being clipped.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (_suppressNoMatchFeedback || !_canListen) return false;
      _listening = true;
      _processing = false;
      notifyListeners();
      final awaitingAdd = _prompt is _AddPrompt;
      final answer = awaitingAdd
          ? await listener.listenForTranscript(baseTimeout: duration)
          : null;
      final recognized = awaitingAdd
          ? answer != null && await _resolvePendingFromSpeech(answer)
          : await listener.listenForCommand(baseTimeout: duration);
      if (!recognized && !_suppressNoMatchFeedback && _canListen) {
        final heardSomething = _lastHeard?.trim().isNotEmpty == true;
        await _tts?.speak(
          heardSomething
              ? 'I did not understand that command. Please try again.'
              : 'I did not hear you. Tap the microphone and try again.',
          heardSomething
              ? 'Hindi ko naintindihan ang utos. Pakiulit.'
              : 'Wala akong narinig. Pindutin ang mikropono at subukan muli.',
        );
      }
      if (recognized && _canListen) {
        await _openContinuationWindow(listener);
      }
      return recognized;
    } finally {
      _continuationHops = 0;
      await listener.stop();
      _listening = false;
      _processing = false;
      _commandSessionActive = false;
      _partialHeard = null;
      _signalVoiceInteractionIdle();
      notifyListeners();
    }
  }

  /// Holds the microphone open after an answer. A pending prompt is resolved
  /// from the transcript; anything else runs as a normal command, bounded by
  /// [maxContinuationHops] so the microphone cannot stay open indefinitely.
  Future<void> _openContinuationWindow(VoskCommandListener listener) async {
    _continuationHops = 0;
    while (_continuationHops < maxContinuationHops && _canListen) {
      final text = await listener.listenForTranscript(
        baseTimeout: continuationWindow,
        partialExtension: const Duration(seconds: 3),
      );
      if (text == null || text.trim().isEmpty) return;
      if (_suppressNoMatchFeedback || !_canListen) return;
      _lastHeard = text;
      notifyListeners();
      if (await _undoFromSpeech(text)) continue;
      if (await _resolvePendingFromSpeech(text)) continue;
      if (!_canListen) return;
      final command = _dispatcher.dispatch(text);
      if (command == null) {
        await _tts?.speak(
          'I did not understand that. Tap the microphone to try again.',
          'Hindi ko naintindihan iyon. Pindutin ang mikropono at subukan muli.',
        );
        continue;
      }
      _continuationHops++;
      await _handleCommand(command);
    }
  }

  // ------------------------------------------------------------- wake word

  /// Accept common Vosk spellings and syllable splits without waking on a
  /// greeting alone or on ordinary mentions of medicine.
  static bool isWakeWord(String text) {
    final words = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .split(' ')
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return false;

    const greetings = {
      'hello',
      'hi',
      'hey',
      'hoy',
      'uy',
      'kumusta',
      'ok',
      'okay',
    };
    const nameSpellings = {
      'medisense',
      'medisens',
      'medisena',
      'medisina',
      'medisen',
      'medisine',
      'medicene',
      'midisense',
      'midisens',
      'midisins',
      'medisins',
      'medesense',
      'medesens',
    };
    for (var start = 0; start < words.length; start++) {
      final greetedBeforePhrase = words.take(start).any(greetings.contains);
      var phrase = '';
      for (var end = start; end < words.length && end < start + 4; end++) {
        phrase += words[end];
        if (nameSpellings.contains(phrase) ||
            (greetedBeforePhrase && phrase == 'medicine') ||
            medicationEditDistance(phrase, 'medisense', maxDistance: 2) <= 2) {
          return true;
        }
        // Short fragments are accepted only after a greeting. This handles
        // transcripts such as "hey medi", "hello sense", or "hey me di".
        if (greetedBeforePhrase &&
            (medicationEditDistance(phrase, 'medi', maxDistance: 1) <= 1 ||
                medicationEditDistance(phrase, 'sense', maxDistance: 1) <= 1 ||
                medicationEditDistance(phrase, 'midi', maxDistance: 1) <= 1 ||
                medicationEditDistance(phrase, 'sins', maxDistance: 1) <= 1)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Starts idle wake-word polling. Safe to call before the model exists.
  void enableWakeWord() {
    if (_disposed || !_pushToTalkMode || !_isForeground) return;
    if (_listener == null) return;
    _wakeArmed = true;
    _ensureWakeLoop();
    notifyListeners();
  }

  void disableWakeWord() {
    if (!_wakeArmed && _wakeLoop == null) return;
    _wakeArmed = false;
    _wakeSuspended = false;
    unawaited(_listener?.stop());
    _notifyIfActive();
  }

  /// Interrupts an in-flight poll so a tap can own the microphone. Returns
  /// whether polling should be restarted afterwards.
  Future<bool> _suspendWakeWord() async {
    if (!_wakeArmed) return false;
    _wakeSuspended = true;
    // Completes the pending poll with null, which ends the loop.
    await _listener?.stop();
    // Wait for the loop's own cleanup so [_releaseWakeWord] never races it and
    // leaves the microphone armed with nothing polling.
    final loop = _wakeLoop;
    if (loop != null) {
      try {
        await loop;
      } catch (_) {}
    }
    return true;
  }

  /// Restarts polling after a tap or a guided answer released the microphone.
  void _ensureWakeLoop() {
    if (!_wakeArmed || _wakeSuspended || _wakeLoop != null) return;
    if (_disposed ||
        !_pushToTalkMode ||
        !_isForeground ||
        _pauseCount > 0 ||
        _listener == null) {
      return;
    }
    final token = Object();
    _wakeToken = token;
    _wakeLoop = _runWakeLoop(token);
  }

  /// Counterpart to [_suspendWakeWord]: hand the microphone back to the poller.
  void _releaseWakeWord() {
    _wakeSuspended = false;
    _ensureWakeLoop();
  }

  Future<void> _runWakeLoop(Object token) async {
    var failed = false;
    try {
      while (_wakeArmed &&
          !_wakeSuspended &&
          !_disposed &&
          _isForeground &&
          _pushToTalkMode &&
          _pauseCount == 0) {
        final listener = _listener;
        if (listener == null) return;
        if (_commandSessionActive || _activeScanAnswer != null) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          continue;
        }
        final text = await listener.listenForTranscript(
          baseTimeout: wakeIdleTimeout,
          partialExtension: wakePartialExtension,
          preferTranscript: isWakeWord,
        );
        if (_wakeSuspended || !_wakeArmed) return;
        if (text == null || !isWakeWord(text)) continue;
        debugPrint('Voice wake phrase detected; opening command prompt.');
        _lastHeard = text;
        // Show the mic as active immediately after the wake phrase, including
        // while TTS plays the short "what can I help with?" cue.
        _listening = true;
        notifyListeners();
        AccessibilityFeedback.voiceOpened();
        await _runCommandWindow(listener, const Duration(seconds: 8));
      }
    } catch (error) {
      failed = true;
      debugPrint('Wake word listener stopped: $error');
    } finally {
      // Clear only our own slot: a newer loop may already own the microphone.
      if (identical(_wakeToken, token)) {
        _wakeLoop = null;
        _wakeToken = null;
      }
      // A pause can release just before listenForTranscript finishes stopping
      // its native recorder. In that order _releaseWakeWord() sees the old
      // future and cannot start another poll; restart here once its slot clears.
      if (!failed) _ensureWakeLoop();
    }
  }

  // ------------------------------------------------------- prompt resolution

  Future<bool> _resolvePendingFromSpeech(String text) async {
    final prompt = _prompt;
    if (prompt == null) return false;

    if (prompt is _AddPrompt) {
      await _resolveAddAnswer(prompt, text);
      return true;
    }

    if (prompt is _TakePrompt) {
      if (ScanSpeechParser.isNo(text)) {
        _prompt = null;
        notifyListeners();
        await _tts?.speak('Okay, not marked.', 'Okay, hindi itinala.');
        return true;
      }
      if (ScanSpeechParser.isYes(text)) {
        await _commitTaken(prompt.doses);
        return true;
      }
      return false;
    }

    if (prompt is _ChoicePrompt) {
      if (ScanSpeechParser.isNo(text)) {
        _prompt = null;
        notifyListeners();
        await _tts?.speak('Okay.', 'Okay.');
        return true;
      }
      final index = ordinalFromSpeech(text);
      if (index != null && index >= 0 && index < prompt.options.length) {
        _prompt = null;
        notifyListeners();
        await _prepareTakeFor(prompt.options[index]);
        return true;
      }
      // The user may simply say the medicine name properly this time.
      final match = _resolveMedicationName(text);
      final chosen =
          match.exact ??
          (match.ambiguous.length == 1 ? match.ambiguous.single : null);
      if (chosen != null) {
        _prompt = null;
        notifyListeners();
        await _prepareTakeFor(chosen);
        return true;
      }
      return false;
    }

    if (prompt is _MovePrompt) {
      if (ScanSpeechParser.isNo(text)) {
        _prompt = null;
        notifyListeners();
        await _tts?.speak(
          'Okay, I left the time alone.',
          'Okay, hindi ko binago ang oras.',
        );
        return true;
      }
      if (ScanSpeechParser.isYes(text)) {
        await _confirmReschedule(prompt);
        return true;
      }
      return false;
    }

    if (prompt is _RemovePrompt) {
      if (ScanSpeechParser.isNo(text)) {
        _prompt = null;
        notifyListeners();
        await _tts?.speak(
          'Okay, I will not remove it.',
          'Okay, hindi ko ito aalisin.',
        );
        return true;
      }
      // "Yes" is deliberately not accepted here: removing a medicine always
      // needs the on-screen dialog.
      return false;
    }
    return false;
  }

  /// Marks the first due dose, then re-prompts for the rest so a spoken "yes"
  /// can clear a whole check-in without a tap per medicine.
  Future<void> _commitTaken(
    List<({Medication med, ScheduleTime s})> doses,
  ) async {
    if (doses.isEmpty) {
      _prompt = null;
      notifyListeners();
      return;
    }
    final dose = doses.first;
    final result = await _medications?.toggleDoseStatus(
      dose.med.id,
      dose.s.id,
      true,
    );
    if (result != DoseStatusChangeResult.updated) {
      _prompt = null;
      notifyListeners();
      final message = switch (result) {
        DoseStatusChangeResult.expired => (
          'This medicine is expired. Do not take it.',
          'Expired na ang gamot na ito. Huwag itong inumin.',
        ),
        DoseStatusChangeResult.recentlyTaken ||
        DoseStatusChangeResult.alreadySet => (
          'This dose was already marked as taken. I did not record it again.',
          'Naitala na ang dose na ito. Hindi ko na ito itinala muli.',
        ),
        DoseStatusChangeResult.readOnly => (
          'This caregiver view cannot change the patient schedule.',
          'Hindi makakapagbago ng iskedyul mula sa caregiver view.',
        ),
        _ => (
          'I could not update this dose.',
          'Hindi ko na-update ang dose na ito.',
        ),
      };
      await _tts?.speak(message.$1, message.$2);
      return;
    }
    _rememberUndoableTake(dose);
    AccessibilityFeedback.doseCompleted();
    final remaining = doses.skip(1).toList();
    if (remaining.isEmpty) {
      _prompt = null;
      notifyListeners();
      final name = _spokenName(dose.med);
      await _tts?.speak(
        '$name marked as taken. Say undo to change it.',
        'Itinala nang nainom ang $name. Sabihin undo para baguhin.',
      );
      return;
    }
    _prompt = _TakePrompt(remaining);
    notifyListeners();
    final name = _spokenName(dose.med);
    final more = remaining.length;
    await _tts?.speak(
      '$name marked as taken. $more more due. Say yes for the next one.',
      'Itinala nang nainom ang $name. May $more pang owing. Sabihin oo para sa susunod.',
    );
  }

  Future<bool> _undoFromSpeech(String text) async {
    if (_undoableTakes.isEmpty) return false;
    // "back" and "balik" are deliberately absent: the dispatcher maps them to
    // the dashboard, so treating them as undo would hijack navigation.
    if (!RegExp(
      r'\b(undo|undoin|bawiin|ibalik|reverse)\b',
    ).hasMatch(text.toLowerCase())) {
      return false;
    }
    final dose = _undoableTakes.removeLast();
    await _medications?.toggleDoseStatus(dose.med.id, dose.s.id, false);
    final name = _spokenName(dose.med);
    await _tts?.speak('$name is pending again.', 'Pending na ulit ang $name.');
    return true;
  }

  /// "the first one", "number two", "una", "isa" -> zero-based index. Public so
  /// the ordering rule can be tested on its own.
  static int? ordinalFromSpeech(String text) {
    const words = <String, int>{
      'una': 0,
      'unang': 0,
      'isa': 0,
      'one': 0,
      '1': 0,
      'first': 0,
      'dalawa': 1,
      'dalawang': 1,
      'two': 1,
      '2': 1,
      'second': 1,
      'tatlo': 2,
      'tatlong': 2,
      'three': 2,
      '3': 2,
      'third': 2,
    };
    for (final entry in words.entries) {
      if (RegExp('\\b${RegExp.escape(entry.key)}\\b').hasMatch(text)) {
        return entry.value;
      }
    }
    return null;
  }

  // ---------------------------------------------------------- name matching

  /// Resolves a spoken medicine name. Exact names win; several exact matches
  /// become a choice; near misses (the common ASR failure) become suggestions.
  _NameMatch _resolveMedicationName(String spoken) {
    final medications = _medications?.medications ?? const <Medication>[];
    final want = _normalizeMedicationName(spoken);
    if (want.isEmpty) return const _NameMatch();

    final exact = <Medication>[];
    final partial = <Medication>[];
    final scored = <Medication, int>{};

    for (final medication in medications) {
      final name = _normalizeMedicationName(medication.name);
      if (name.isEmpty) continue;
      if (name == want) {
        exact.add(medication);
        continue;
      }
      if (name.contains(want) || want.contains(name)) {
        partial.add(medication);
        continue;
      }
      final score = nameWordDistance(want, name);
      if (score != null) scored[medication] = score;
    }

    if (exact.length == 1) return _NameMatch(exact: exact.single);
    if (exact.length > 1) return _NameMatch(ambiguous: exact);

    if (partial.length == 1) return _NameMatch(exact: partial.single);
    if (partial.length > 1) return _NameMatch(ambiguous: partial);

    final suggestions = scored.entries.toList()
      ..sort((a, b) {
        final distance = a.value.compareTo(b.value);
        return distance != 0
            ? distance
            : a.key.name.toLowerCase().compareTo(b.key.name.toLowerCase());
      });
    return _NameMatch(
      suggestions: suggestions
          .take(_maxNameSuggestions)
          .map((entry) => entry.key)
          .toList(),
    );
  }

  /// Total word-level edit distance between two normalized names, or null when
  /// any spoken word matches nothing in the candidate. A single wrong word is
  /// the realistic ASR error, so one word is allowed to be a near miss.
  ///
  /// Public so the matching rule can be tested without a provider harness.
  static int? nameWordDistance(String want, String name) {
    final wantWords = want.split(' ');
    final nameWords = name.split(' ');
    if ((wantWords.length - nameWords.length).abs() > 1) return null;
    var total = 0;
    for (final word in wantWords) {
      var best = 99;
      for (final candidate in nameWords) {
        final distance = medicationEditDistance(
          word,
          candidate,
          maxDistance: 2,
        );
        if (distance < best) best = distance;
      }
      // 3 is the out-of-band sentinel for maxDistance 2.
      if (best > 2) return null;
      total += best;
    }
    return total <= 2 ? total : null;
  }

  static String _normalizeMedicationName(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  String _spokenName(Medication medication) {
    final name = MedicineSpeechFormatter.medicineName(medication.name);
    return name.isEmpty ? medication.name : name;
  }

  // ------------------------------------------------------------ command work

  Future<void> _handleCommand(VoskCommand command) async {
    if (_disposed || !_pushToTalkMode || !_isForeground) return;
    command = _preferKnownMedicationName(command);
    if (command.route.isNotEmpty) {
      if (command.route == '/schedule' &&
          _router?.routerDelegate.currentConfiguration.uri.path !=
              '/schedule') {
        _suppressNextScheduleGreeting = true;
      }
      _router?.go(command.route);
      AccessibilityFeedback.pageChanged();
    }
    switch (command.intent) {
      case VoskVoiceIntent.medicationSchedule:
      case VoskVoiceIntent.periodSchedule:
        await _tts?.speak(
          _scheduleReadout(period: command.period),
          _scheduleReadout(filipino: true, period: command.period),
        );
      case VoskVoiceIntent.nextDose:
        final (english, filipino) = _nextDoseReadout();
        await _tts?.speak(english, filipino);
      case VoskVoiceIntent.markTaken:
        await _prepareMarkTaken(command);
      case VoskVoiceIntent.removeMedication:
        await _prepareMedicationRemoval(command);
      case VoskVoiceIntent.rescheduleMedication:
        await _prepareReschedule(command);
      case VoskVoiceIntent.addMedication:
        await _prepareAdd(command);
      case VoskVoiceIntent.snooze:
        await _snoozeDose();
      case VoskVoiceIntent.adherenceSummary:
        final (english, filipino) = _adherenceReadout();
        await _tts?.speak(english, filipino);
      case VoskVoiceIntent.expiringSoon:
        final (english, filipino) = _expiringReadout();
        await _tts?.speak(english, filipino);
      case VoskVoiceIntent.volumeUp:
        await _changeVoiceVolume(1);
      case VoskVoiceIntent.volumeDown:
        await _changeVoiceVolume(-1);
      case VoskVoiceIntent.repeat:
        if (_tts?.lastSpoken?.isNotEmpty == true) {
          await _tts?.repeatLast();
        } else {
          await _tts?.speak(
            'There is nothing to repeat yet.',
            'Wala pa akong maulit.',
          );
        }
      case VoskVoiceIntent.scan:
      case VoskVoiceIntent.dashboard:
      case VoskVoiceIntent.settings:
      case VoskVoiceIntent.profile:
      case VoskVoiceIntent.guardian:
      case VoskVoiceIntent.userManual:
      case VoskVoiceIntent.accessibility:
      case VoskVoiceIntent.privacy:
      case VoskVoiceIntent.terms:
      case VoskVoiceIntent.help:
        await _tts?.speak(command.englishReply, command.filipinoReply);
      case VoskVoiceIntent.whereAmI:
        speakWhereContext(
          _router?.routerDelegate.currentConfiguration.uri.path ?? '/',
        );
      case VoskVoiceIntent.readScreen:
        readCurrentScreen();
    }
  }

  /// The voice command already speaks the schedule readout. Suppress the
  /// schedule screen's arrival greeting for that one route transition so it
  /// cannot replace the answer while it is being spoken.
  bool consumeScheduleGreetingSuppression() {
    final suppress = _suppressNextScheduleGreeting;
    _suppressNextScheduleGreeting = false;
    return suppress;
  }

  Future<void> _prepareMarkTaken(VoskCommand command) async {
    final provider = _medications;
    final target = command.medicationName;
    if (provider == null || target == null) {
      _prompt = _TakePrompt(
        List<({Medication med, ScheduleTime s})>.of(
          provider?.dosesDueNow ?? const [],
        ),
      );
      notifyListeners();
      await _tts?.speak(command.englishReply, command.filipinoReply);
      return;
    }

    final match = _resolveMedicationName(target);
    final medication =
        match.exact ??
        (match.ambiguous.length == 1 ? match.ambiguous.single : null);
    if (medication == null) {
      await _offerMedicationChoices(target, match);
      return;
    }
    await _prepareTakeFor(medication);
  }

  /// Offers the closest schedule names instead of a dead end, then lets the
  /// user answer by number or by saying the name again.
  Future<void> _offerMedicationChoices(String spoken, _NameMatch match) async {
    final options = match.ambiguous.isNotEmpty
        ? match.ambiguous
        : match.suggestions;
    if (options.isEmpty) {
      _prompt = null;
      await _tts?.speak(
        'I could not find $spoken in your medication schedule.',
        'Hindi ko makita ang $spoken sa iskedyul ng mga gamot mo.',
      );
      return;
    }
    _prompt = _ChoicePrompt(spoken: spoken, options: options);
    notifyListeners();
    if (options.length == 1) {
      await _tts?.speak(
        'Did you mean ${options.first.name}?',
        'Ang ibig sabihin mo ba ay ${options.first.name}?',
      );
      return;
    }
    final names = options.take(3).map((med) => med.name).join(' or ');
    final filipino = options.take(3).map((med) => med.name).join(' o ');
    await _tts?.speak(
      'Did you mean $names?',
      'Ang ibig sabihin mo ba ay $filipino?',
    );
  }

  /// Fills the dose slot for a resolved medicine and asks for confirmation.
  Future<void> _prepareTakeFor(Medication medication) async {
    if (medication.isExpired) {
      _prompt = null;
      notifyListeners();
      await _tts?.speak(
        'This medicine is expired. Do not take ${medication.name}.',
        'Expired na ang medicine na to. Huwag inumin ang ${medication.name}.',
      );
      return;
    }

    final due = MedicationProvider.dosesDueNowFor([
      medication,
    ], TimeOfDay.now());
    final pending = due.isNotEmpty
        ? due
        : medication.schedule
              .where((schedule) => !schedule.taken)
              .map((schedule) => (med: medication, s: schedule))
              .toList();
    if (pending.isEmpty) {
      _prompt = null;
      notifyListeners();
      await _tts?.speak(
        '${medication.name} is already marked as taken for today.',
        'Naka-mark na nang nainom ang ${medication.name} ngayong araw.',
      );
      return;
    }
    _prompt = _TakePrompt(pending);
    notifyListeners();
    final spoken = _spokenName(medication);
    await _tts?.speak(
      pending.length == 1
          ? 'Confirm that you took $spoken. Say yes.'
          : 'You have ${pending.length} doses of $spoken due. Say yes for the first.',
      pending.length == 1
          ? 'Kumpirmahin kung nainom mo na ang $spoken. Sabihin oo.'
          : 'May $pending.length na dose ng $spoken na owing. Sabihin oo para sa una.',
    );
  }

  Future<void> _prepareMedicationRemoval(VoskCommand command) async {
    final target = command.medicationName;
    final match = target == null
        ? const _NameMatch()
        : _resolveMedicationName(target);
    final medication =
        match.exact ??
        (match.ambiguous.length == 1 ? match.ambiguous.single : null);
    if (_medications?.isViewingPatient == true) {
      _prompt = null;
      await _tts?.speak(
        'You cannot remove medicine from a caregiver view.',
        'Hindi maaaring mag-alis ng gamot mula sa caregiver view.',
      );
      return;
    }
    if (medication == null) {
      await _offerMedicationChoices(target ?? 'that medicine', match);
      return;
    }
    _prompt = _RemovePrompt(medication);
    notifyListeners();
    await _tts?.speak(
      'Do you want to remove ${medication.name}? Confirm on screen.',
      'Alisin ba ang ${medication.name}? Kumpirmahin sa screen.',
    );
  }

  /// Proposes a new dose time and waits for a spoken yes. This is the one
  /// change a misheard single word ("eight" -> "ate") can silently make, so it
  /// never applies on the recognition alone.
  Future<void> _prepareReschedule(VoskCommand command) async {
    final target = command.medicationName;
    final match = target == null
        ? const _NameMatch()
        : _resolveMedicationName(target);
    final medication =
        match.exact ??
        (match.ambiguous.length == 1 ? match.ambiguous.single : null);
    final hour = command.hour;
    final minute = command.minute;
    _prompt = null;
    if (medication == null || hour == null || minute == null) {
      if (medication == null && target != null) {
        await _offerMedicationChoices(target, match);
        return;
      }
      await _tts?.speak(
        'I could not match that medicine and time. Say, move Biogesic to 8 AM.',
        'Hindi ko matukoy ang gamot at oras. Sabihin, ilipat ang Biogesic sa alas otso ng umaga.',
      );
      return;
    }
    if (_medications?.isViewingPatient == true) {
      await _tts?.speak(
        'You cannot change a caregiver view schedule.',
        'Hindi mababago ang iskedyul mula sa caregiver view.',
      );
      return;
    }
    final schedule = _scheduleToMove(medication);
    if (schedule == null) {
      await _tts?.speak(
        '${medication.name} has no scheduled dose to move.',
        'Walang nakatakdang dose ng ${medication.name} na maililipat.',
      );
      return;
    }
    final time = TimeOfDay(hour: hour, minute: minute);
    _prompt = _MovePrompt(medication: medication, time: time);
    notifyListeners();
    final formatted = ScheduleTime.formatTime(time);
    await _tts?.speak(
      'Move ${medication.name} to $formatted? Say yes to confirm.',
      'Ilipat ang ${medication.name} sa $formatted? Sabihin oo para kumpirmahin.',
    );
  }

  Future<void> _confirmReschedule(_MovePrompt prompt) async {
    _prompt = null;
    notifyListeners();
    final updated = await _medications?.moveScheduleTime(
      prompt.medication.id,
      _scheduleToMove(prompt.medication)?.id ?? '',
      prompt.time,
    );
    if (updated != true) {
      await _tts?.speak(
        'I could not update that medication schedule.',
        'Hindi ko na-update ang iskedyul ng gamot na iyon.',
      );
      return;
    }
    final formatted = ScheduleTime.formatTime(prompt.time);
    await _tts?.speak(
      'I moved ${prompt.medication.name} to $formatted.',
      'Inilipat ko ang ${prompt.medication.name} sa $formatted.',
    );
  }

  /// Captures each safety-critical field before asking for spoken confirmation.
  Future<void> _prepareAdd(VoskCommand command) async {
    final name = command.medicationName;
    if (name == null || name.trim().isEmpty) {
      await _tts?.speak(
        'I did not hear the medicine name. Try, add Biogesic once a day.',
        'Hindi ko marinig ang pangalan ng gamot. Sabihin, magdagdag ng Biogesic minsan sa araw.',
      );
      return;
    }
    if (_medications?.isViewingPatient == true) {
      await _tts?.speak(
        'A caregiver view cannot add medicine to the patient schedule.',
        'Hindi maaaring magdagdag ng gamot mula sa caregiver view.',
      );
      return;
    }
    _prompt = _AddPrompt(name.trim());
    notifyListeners();
    await _tts?.speak(
      'Adding $name. Say the dose with its unit, for example 500 milligrams. Say cancel at any time.',
      'Idinadagdag ang $name. Sabihin ang dose at unit, halimbawa 500 milligrams. Sabihin cancel para huminto.',
    );
  }

  Future<void> _resolveAddAnswer(_AddPrompt prompt, String text) async {
    final answer = text.trim().toLowerCase();
    if (RegExp(r'\b(cancel|stop|kanselahin|hinto)\b').hasMatch(answer)) {
      _prompt = null;
      notifyListeners();
      await _tts?.speak(
        'Medicine entry cancelled.',
        'Kinansela ang pagdagdag ng gamot.',
      );
      return;
    }
    switch (prompt.stage) {
      case _AddStage.dose:
        final dose = VoiceMedicationInput.dose(answer);
        if (dose == null) {
          await _tts?.speak(
            'I need a number and unit. Say, for example, 500 milligrams or 5 milliliters.',
            'Kailangan ang bilang at unit. Halimbawa, 500 milligrams o 5 milliliters.',
          );
          return;
        }
        prompt.dose = dose;
        prompt.stage = _AddStage.form;
        await _tts?.speak(
          'What form is ${prompt.name}? Say tablet, capsule, syrup, drops, or inhaler.',
          'Anong anyo ng gamot? Sabihin tablet, capsule, syrup, drops, o inhaler.',
        );
      case _AddStage.form:
        final forms = <String, String>{
          'tablet': 'Tablet',
          'tableta': 'Tablet',
          'capsule': 'Capsule',
          'kapsula': 'Capsule',
          'syrup': 'Syrup',
          'sirup': 'Syrup',
          'drops': 'Drops',
          'patak': 'Drops',
          'inhaler': 'Inhaler',
          'cream': 'Cream',
        };
        String? form;
        for (final entry in forms.entries) {
          if (RegExp('\\b${entry.key}\\b').hasMatch(answer)) {
            form = entry.value;
            break;
          }
        }
        if (form == null) {
          await _tts?.speak(
            'Say the medicine form, such as tablet or syrup.',
            'Sabihin ang anyo ng gamot, gaya ng tablet o syrup.',
          );
          return;
        }
        prompt.form = form;
        prompt.stage = _AddStage.expiry;
        await _tts?.speak(
          'Say the expiry as month slash year, for example 03 slash 2027. Say unknown if it is not available.',
          'Sabihin ang expiry na buwan at taon, halimbawa 03 slash 2027. Sabihin unknown kung wala.',
        );
      case _AddStage.expiry:
        if (RegExp(r'\b(unknown|none|wala|hindi alam)\b').hasMatch(answer)) {
          prompt.expiry = null;
        } else {
          final expiry = VoiceMedicationInput.expiry(answer);
          if (expiry == null || expiry.isBefore(DateTime.now())) {
            await _tts?.speak(
              'I could not confirm a future expiry. Say month and year, or say unknown.',
              'Hindi matukoy ang expiry. Sabihin ang buwan at taon, o unknown.',
            );
            return;
          }
          prompt.expiry = expiry;
        }
        prompt.stage = _AddStage.frequency;
        await _tts?.speak(
          'How often? Say once a day, twice a day, or as needed.',
          'Gaano kadalas? Sabihin once a day, twice a day, o as needed.',
        );
      case _AddStage.frequency:
        final frequency = ScanSpeechParser.frequencyFromSpeech(answer);
        if (frequency == null) {
          await _tts?.speak(
            'I did not understand the frequency. Say once a day, twice a day, or as needed.',
            'Hindi malinaw ang dalas. Sabihin once a day, twice a day, o as needed.',
          );
          return;
        }
        prompt.frequency = frequency;
        if (frequency == 'As needed') {
          prompt.stage = _AddStage.confirm;
          await _readAddSummary(prompt);
        } else {
          prompt.stage = _AddStage.time;
          await _tts?.speak(
            'What time is the first dose? Include A M or P M, for example 8 A M.',
            'Anong oras ang unang dose? Sabihin A M o P M, halimbawa 8 A M.',
          );
        }
      case _AddStage.time:
        final time = ScanSpeechParser.timeFromSpeech(answer);
        if (time == null ||
            !RegExp(
              r'\b(am|pm|a m|p m|umaga|gabi|hapon|tanghali)\b',
            ).hasMatch(answer)) {
          await _tts?.speak(
            'Say a time with A M or P M, for example 8 A M.',
            'Sabihin ang oras na may A M o P M, halimbawa 8 A M.',
          );
          return;
        }
        prompt.time = time;
        prompt.stage = _AddStage.confirm;
        await _readAddSummary(prompt);
      case _AddStage.confirm:
        if (ScanSpeechParser.isNo(answer)) {
          _prompt = null;
          notifyListeners();
          await _tts?.speak(
            'Medicine entry cancelled. Start again to correct it.',
            'Kinansela ang pagdagdag. Simulan muli para itama.',
          );
          return;
        }
        if (!ScanSpeechParser.isYes(answer)) {
          await _tts?.speak(
            'Say yes to save, or no to cancel.',
            'Sabihin yes para i-save, o no para kanselahin.',
          );
          return;
        }
        final id = DateTime.now().microsecondsSinceEpoch.toString();
        final medication = Medication(
          id: id,
          name: prompt.name,
          dosage: prompt.dose!,
          form: prompt.form!,
          expirationDate: prompt.expiry,
          frequency: prompt.frequency!,
          schedule: prompt.time == null
              ? []
              : ScheduleTime.buildSchedule(
                  medId: id,
                  start: prompt.time!,
                  frequency: prompt.frequency!,
                ),
        );
        _prompt = null;
        notifyListeners();
        try {
          await _medications!.addMedication(medication);
          await _tts?.speak(
            '${prompt.name} was saved. Check the schedule for accuracy.',
            'Nai-save ang ${prompt.name}. Suriin ang iskedyul.',
          );
        } on Object {
          await _tts?.speak(
            'I could not save this medicine. Please try again.',
            'Hindi nai-save ang gamot. Pakisubukan muli.',
          );
        }
    }
  }

  Future<void> _readAddSummary(_AddPrompt prompt) async {
    final expiry = prompt.expiry == null
        ? 'expiry unknown'
        : 'expires ${MedicineExpiryParser.formatStored(prompt.expiry!)}';
    final time = prompt.time == null
        ? ''
        : ', first dose at ${ScheduleTime.formatTime(prompt.time!)}';
    await _tts?.speak(
      'Confirm: ${prompt.name}, ${prompt.dose}, ${prompt.form}, $expiry, ${prompt.frequency}$time. Say yes to save or no to cancel.',
      'Kumpirmahin: ${prompt.name}, ${prompt.dose}, ${prompt.form}, $expiry, ${prompt.frequency}$time. Sabihin yes para i-save o no para kanselahin.',
    );
  }

  VoskCommand _preferKnownMedicationName(VoskCommand command) {
    for (final name in command.medicationNameAlternatives) {
      final match = _resolveMedicationName(name);
      if (match.exact != null || match.ambiguous.isNotEmpty) {
        return command.withMedicationName(name);
      }
    }
    return command;
  }

  /// Defers the dose that is due now. The reminder fires again shortly; the
  /// original schedule is untouched.
  Future<void> _snoozeDose() async {
    final due = _medications?.dosesDueNow ?? const [];
    if (due.isEmpty) {
      await _tts?.speak(
        'There is no dose due right now to put off.',
        'Walang dose na owing ngayon na pwede ipagpalit.',
      );
      return;
    }
    final dose = due.first;
    final name = _spokenName(dose.med);
    await _tts?.speak(
      'I will remind you about $name again in a few minutes.',
      'Ipaalala ko sa iyo ang $name pagkalipas ng ilang minuto.',
    );
    unawaited(
      _medications?.snoozeDose(medId: dose.med.id, scheduleId: dose.s.id),
    );
  }

  /// "How am I doing?" — today's counts, then anything that needs attention.
  (String, String) _adherenceReadout() {
    final medications = _medications?.medications ?? const <Medication>[];
    if (medications.isEmpty) {
      return (
        'You have no medicines saved yet.',
        'Wala ka pang nakaimbak na gamot.',
      );
    }
    final due = _medications?.dosesDueNow.length ?? 0;
    final total = medications.fold<int>(0, (sum, m) => sum + m.dailyDoses);
    final taken = medications.fold<int>(0, (sum, m) => sum + m.takenDoses);
    final counts =
        'You have taken $taken of $total doses today. '
        '${due == 0
            ? 'Nothing is due right now.'
            : due == 1
            ? '1 dose is due now.'
            : '$due doses are due now.'}';
    final filipinoCounts =
        '$taken na sa $total na dose ang nainom mo ngayong araw. '
        '${due == 0
            ? 'Walang owing ngayon.'
            : due == 1
            ? 'May 1 na owing.'
            : 'May $due na owing.'}';

    final attention = _attentionMedications();
    if (attention.english.isEmpty) return (counts, filipinoCounts);
    return (
      '$counts ${attention.english}',
      '$filipinoCounts ${attention.filipino}',
    );
  }

  /// Expired and soon-to-run-out medicines, most urgent first.
  (String, String) _expiringReadout() {
    final medications = _medications?.medications ?? const <Medication>[];
    final attention = _attentionMedications();
    if (medications.isEmpty || attention.english.isEmpty) {
      return (
        'None of your medicines are expired or close to running out.',
        'Walang naganap na expiring o malapit nang maubos na gamot.',
      );
    }
    return (
      'Here is what needs attention. ${attention.english}',
      'Ito ang kailangang pansinin. ${attention.filipino}',
    );
  }

  /// Bilingual, expiring-first. An expired medicine is a warning, not a note.
  ({String english, String filipino}) _attentionMedications() {
    final medications = _medications?.medications ?? const <Medication>[];
    final english = <String>[];
    final filipino = <String>[];
    final ordered =
        medications
            .where((medication) => medication.daysUntilExpiry != null)
            .toList()
          ..sort((a, b) => a.daysUntilExpiry!.compareTo(b.daysUntilExpiry!));
    for (final medication in ordered) {
      if (medication.isExpired) {
        english.add('${medication.name} expired, do not take it');
        filipino.add('${medication.name} expired na, huwag inumin');
        continue;
      }
      if (!medication.isExpiringSoon) continue;
      final days = medication.daysUntilExpiry!;
      final when = days == 0
          ? 'today'
          : days == 1
          ? 'tomorrow'
          : 'in $days days';
      final filipinoWhen = days == 0
          ? 'ngayong araw'
          : days == 1
          ? 'bukas'
          : 'sa loob ng $days araw';
      english.add('${medication.name} expires $when');
      final runOut = medication.estimatedRunOutDate;
      filipino.add(
        runOut == null
            ? '${medication.name} mag-e-expire $filipinoWhen'
            : '${medication.name} mag-e-expire $filipinoWhen, wala nang laman '
                  'around ${DateFormat('MMMM d').format(runOut)}',
      );
    }
    if (english.isEmpty) return (english: '', filipino: '');
    return (
      english: '${english.join('. ')}.',
      filipino: '${filipino.join('. ')}.',
    );
  }

  ScheduleTime? _scheduleToMove(Medication medication) {
    if (medication.schedule.isEmpty) return null;
    final pending = medication.schedule.where((schedule) => !schedule.taken);
    final candidates = pending.isEmpty ? medication.schedule : pending.toList();
    final now = TimeOfDay.now().hour * 60 + TimeOfDay.now().minute;
    candidates.sort((a, b) {
      final aMinutes = a.time.hour * 60 + a.time.minute;
      final bMinutes = b.time.hour * 60 + b.time.minute;
      final aIsUpcoming = aMinutes >= now;
      final bIsUpcoming = bMinutes >= now;
      if (aIsUpcoming != bIsUpcoming) return aIsUpcoming ? -1 : 1;
      return aMinutes.compareTo(bMinutes);
    });
    return candidates.first;
  }

  Future<void> confirmRemoveMedication() async {
    final prompt = _prompt;
    _prompt = null;
    notifyListeners();
    if (prompt is! _RemovePrompt) return;
    await _medications?.removeMedication(prompt.medication.id);
    await _tts?.speak(
      '${prompt.medication.name} was removed from your schedule.',
      'Nalis na ang ${prompt.medication.name} sa iskedyul mo.',
    );
  }

  void cancelRemoveMedication() {
    if (_prompt is! _RemovePrompt) return;
    _prompt = null;
    notifyListeners();
  }

  Future<void> _changeVoiceVolume(int direction) async {
    final tts = _tts;
    final appState = _appState;
    if (tts == null || appState == null) return;
    final current = VoiceLevels.levelFor(
      appState.ttsVolume,
      VoiceLevels.volume,
    );
    final target = (current + direction).clamp(1, VoiceLevels.volume.length);
    if (target == current) {
      await tts.speak(
        direction > 0
            ? 'Voice is already at maximum volume.'
            : 'Voice is already at minimum volume.',
        direction > 0
            ? 'Nasa pinakamalakas na ang boses ko.'
            : 'Nasa pinakamina na ang boses ko.',
      );
      return;
    }
    final volume = VoiceLevels.valueFor(target, VoiceLevels.volume);
    appState.setTtsVolume(volume);
    await tts.setVolume(volume);
    await tts.speak(
      direction > 0 ? 'Voice volume increased.' : 'Voice volume decreased.',
      direction > 0
          ? 'Nilakasan ko ang boses ko.'
          : 'Hininaan ko ang boses ko.',
    );
  }

  // ------------------------------------------------------------------ pauses

  /// Stops microphone work until the returned handle is released. Always
  /// release it from a `finally` block.
  Future<VoicePause> pauseNavigation() async {
    _pauseCount++;
    _suppressNoMatchFeedback = true;
    try {
      await _listener?.stop();
      await _tts?.stop();
    } catch (error) {
      debugPrint('Voice listener stop failed: $error');
    } finally {
      _listening = false;
      _partialHeard = null;
      notifyListeners();
    }
    return VoicePause(_releaseNavigationPause);
  }

  /// Additionally holds new model loads until image OCR finishes.
  Future<VoicePause> pauseForImageAnalysis() async {
    // An OCR capture may finish after a user has already woken the assistant.
    // Let that bounded interaction finish before taking the mic back for image
    // analysis, so an automatic scan cannot cut off a live user command.
    while (!_disposed && (_commandSessionActive || _activeScanAnswer != null)) {
      await _waitForVoiceInteractionIdle();
    }
    _analysisPauseCount++;
    return _finishImageAnalysisPause();
  }

  /// Pauses only when the user is not actively speaking a command or answer.
  /// Camera framing hints use this so they never cut off wake-word follow-up.
  Future<VoicePause?> tryPauseForImageAnalysis() {
    if (_disposed || _commandSessionActive || _activeScanAnswer != null) {
      return Future<VoicePause?>.value(null);
    }
    _analysisPauseCount++;
    return _finishImageAnalysisPause();
  }

  Future<VoicePause> _finishImageAnalysisPause() async {
    final navigation = await pauseNavigation();
    // Let an in-flight native model load finish so image work does not compete
    // with it. An unavailable voice model must not abort image analysis.
    try {
      await _nativeVoskLoading;
    } catch (_) {}
    return VoicePause(() {
      navigation.release();
      if (_analysisPauseCount > 0) _analysisPauseCount--;
      if (_analysisPauseCount == 0) {
        final resume = _resumeVosk;
        _resumeVosk = null;
        if (resume != null && !resume.isCompleted) resume.complete();
      }
    });
  }

  void _releaseNavigationPause() {
    if (_pauseCount > 0) _pauseCount--;
    // Hand the microphone back once nothing is holding it.
    if (_pauseCount == 0) {
      final released = _navigationPauseReleased;
      _navigationPauseReleased = null;
      if (released != null && !released.isCompleted) released.complete();
      _releaseWakeWord();
    }
    notifyListeners();
  }

  Future<void> _waitForNavigationResume() async {
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (_pauseCount > 0 && !_disposed) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return;
      final released = _navigationPauseReleased ??= Completer<void>();
      try {
        await released.future.timeout(remaining);
      } on TimeoutException {
        // A stuck native OCR request must not leave the mic button waiting
        // forever. The caller checks the pause state before opening audio.
        return;
      }
    }
  }

  Future<void> _waitForVoiceInteractionIdle() async {
    while (!_disposed && (_commandSessionActive || _activeScanAnswer != null)) {
      final idle = _voiceInteractionIdle ??= Completer<void>();
      await idle.future;
    }
  }

  void _signalVoiceInteractionIdle() {
    if (_commandSessionActive || _activeScanAnswer != null) return;
    final idle = _voiceInteractionIdle;
    _voiceInteractionIdle = null;
    if (idle != null && !idle.isCompleted) idle.complete();
  }

  Future<void> stopListening() async {
    _suppressNoMatchFeedback = true;
    try {
      await _listener?.stop();
    } catch (error) {
      debugPrint('Voice listener stop failed: $error');
    }
    try {
      await _tts?.stop();
    } catch (error) {
      debugPrint('Voice TTS stop failed: $error');
    }
    _listening = false;
    _processing = false;
    _partialHeard = null;
    _notifyIfActive();
  }

  // -------------------------------------------------------------- navigation

  void navigateSilently(String route) => _router?.go(route);

  void navigateTo(String route) {
    _router?.go(route);
    AccessibilityFeedback.pageChanged();
  }

  void speakMicTutorial() {
    if (!_pushToTalkMode) return;
    unawaited(
      _speakAnnouncement(
        'Tap the microphone and say open camera, check the camera, scan this, go home, open your prescription, check your medicine schedule, next dose, or help. You can also say hey MediSense to start hands-free.',
        'Pindutin ang mikropono at sabihin ang buksan ang camera, tingnan ang camera, i-scan ito, buksan ang home, tingnan ang reseta o iskedyul ng gamot, susunod na gamot, o tulong. Maaari mo ring sabihin, hey MediSense, para maghands-free.',
      ),
    );
  }

  Future<void> _speakAnnouncement(String english, String filipino) async {
    final pause = await pauseNavigation();
    try {
      if (_pushToTalkMode) await _tts?.speak(english, filipino);
    } finally {
      pause.release();
    }
  }

  void announceScreen(String route) {
    if (!_pushToTalkMode) return;
    final verbosity = _appState?.ttsVerbosity ?? TtsVerbosity.standard;
    // The scanner owns its longer greeting and camera guidance.
    if (route == '/scan' || verbosity == TtsVerbosity.essential) return;
    if (route.startsWith('/medication/')) {
      final id = Uri.decodeComponent(route.substring('/medication/'.length));
      final med = _medications?.getById(id);
      if (med != null) {
        final times = [...med.schedule]
          ..sort(
            (a, b) => (a.time.hour * 60 + a.time.minute).compareTo(
              b.time.hour * 60 + b.time.minute,
            ),
          );
        unawaited(
          _speakAnnouncement(
            verbosity == TtsVerbosity.detailed
                ? '${med.name} details. Strength ${med.dosage}. Scheduled at ${times.map((s) => s.formattedTime).join(', ')}.'
                : '${med.name} details.',
            verbosity == TtsVerbosity.detailed
                ? 'Detalye ng ${med.name}. Lakas ${med.dosage}. Nakatakda sa ${times.map((s) => s.formattedTime).join(', ')}.'
                : 'Detalye ng ${med.name}.',
          ),
        );
        return;
      }
    }
    final named = kVoiceScreenAnnouncements[route];
    if (named != null) {
      unawaited(
        _speakAnnouncement(
          verbosity == TtsVerbosity.detailed
              ? '${named.english}. ${_screenHelp(route, filipino: false)}'
              : named.english,
          verbosity == TtsVerbosity.detailed
              ? '${named.filipino}. ${_screenHelp(route, filipino: true)}'
              : named.filipino,
        ),
      );
      return;
    }
    // No hand-written entry for this route. Describe live state rather than
    // guessing, so a newly added screen stays truthful on its own.
    final medications = _medications?.medications ?? const <Medication>[];
    final due = _medications?.dosesDueNow.length ?? 0;
    if (medications.isEmpty) {
      unawaited(
        _speakAnnouncement(
          'This screen has no medicines to show yet.',
          'Wala pang gamot na ipinapakita ang screen na ito.',
        ),
      );
      return;
    }
    final count = medications.length;
    final pending = count == 1 ? '1 medicine' : '$count medicines';
    final dueText = due == 0
        ? 'Nothing is due right now.'
        : due == 1
        ? '1 dose is due now.'
        : '$due doses are due now.';
    unawaited(
      _speakAnnouncement(
        'This screen. You have $pending. $dueText',
        'Ang screen na ito. May $pending ka. $dueText',
      ),
    );
  }

  String _screenHelp(String route, {required bool filipino}) {
    return switch (route) {
      '/' =>
        filipino
            ? 'Makikita rito ang susunod na gamot at mga paalala.'
            : 'Your next medicine and reminders are here.',
      '/schedule' =>
        filipino
            ? 'Nakaayos ang mga gamot ayon sa oras. Pumili ng gamot para sa detalye.'
            : 'Medicines are ordered by time. Select one for details.',
      '/settings' =>
        filipino
            ? 'Dito mo mababago ang boses, mga anunsiyo, at mga alarm.'
            : 'Change voice, announcements, and alarms here.',
      '/guardian' =>
        filipino
            ? 'Tingnan dito ang mga konektadong tagapangalaga at paanyaya.'
            : 'Review connected guardians and invitations here.',
      '/profile' =>
        filipino
            ? 'Tingnan at baguhin ang impormasyon ng iyong account.'
            : 'Review and update your account information.',
      _ =>
        filipino
            ? 'Gamitin ang mga pindutan sa pahinang ito para magpatuloy.'
            : 'Use the buttons on this screen to continue.',
    };
  }

  void speakWhereContext(String route) {
    if (!_pushToTalkMode) return;
    final next = _medications?.nextPendingDose;
    final where = kVoiceScreenAnnouncements[route]?.english ?? 'this screen';
    if (next == null) {
      unawaited(
        _tts?.speak(
              'You are on $where. No upcoming dose is scheduled.',
              'Nasa $where ka. Wala ka pang susunod na gamot.',
            ) ??
            Future<void>.value(),
      );
      return;
    }
    final name = _spokenName(next.med);
    final strength = MedicineSpeechFormatter.strength(next.med.dosage);
    final medicine = [
      name,
      strength,
    ].where((part) => part.isNotEmpty).join(', ');
    unawaited(
      _tts?.speak(
            'You are on $where. Next: $medicine at ${next.s.formattedTime}.',
            'Nasa $where ka. Susunod: $medicine, sa ${next.s.formattedTime}.',
          ) ??
          Future<void>.value(),
    );
  }

  void readCurrentScreen() {
    if (!_pushToTalkMode) return;
    final route = _router?.routerDelegate.currentConfiguration.uri.path ?? '/';
    if (route == '/schedule') {
      unawaited(
        _tts?.speak(_scheduleReadout(), _scheduleReadout(filipino: true)) ??
            Future<void>.value(),
      );
      return;
    }
    announceScreen(route);
  }

  String _scheduleReadout({bool filipino = false, String? period}) {
    final meds = _medications?.medications ?? <Medication>[];
    final now = DateTime.now();
    final currentBlock = ScheduleTime.labelFor(now.hour);
    final currentIndex = ScheduleTime.blocks.indexOf(currentBlock);
    final spokenExpiryFor = <String>{};
    final doses =
        [
          for (final med in meds)
            for (final time in med.schedule)
              if (period == null || time.label == period)
                (med: med, time: time),
        ]..sort((a, b) {
          if (period == null) {
            final aIndex = ScheduleTime.blocks.indexOf(a.time.label);
            final bIndex = ScheduleTime.blocks.indexOf(b.time.label);
            final aOrder =
                (aIndex - currentIndex + ScheduleTime.blocks.length) %
                ScheduleTime.blocks.length;
            final bOrder =
                (bIndex - currentIndex + ScheduleTime.blocks.length) %
                ScheduleTime.blocks.length;
            if (aOrder != bOrder) return aOrder.compareTo(bOrder);
          }
          final aMinutes = a.time.time.hour * 60 + a.time.time.minute;
          final bMinutes = b.time.time.hour * 60 + b.time.time.minute;
          return aMinutes.compareTo(bMinutes);
        });
    final items = doses.map((dose) {
      final med = dose.med;
      final time = dose.time;
      final name = _spokenName(med);
      final strength = MedicineSpeechFormatter.strength(med.dosage);
      final medicine = [
        name,
        strength,
      ].where((part) => part.isNotEmpty).join(', ');
      final expiry = spokenExpiryFor.add(med.id)
          ? _expiryReadout(med, filipino: filipino)
          : null;
      return filipino
          ? '$medicine, sa ${time.formattedTime}${expiry == null ? '' : ', $expiry'}'
          : '$medicine at ${time.formattedTime}${expiry == null ? '' : ', $expiry'}';
    }).toList();
    final intro = period == null
        ? filipino
              ? 'Ito ang gamot mo sa ${ScheduleTime.filipinoPeriodFor(now.hour)}.'
              : 'Here are your medicines for ${currentBlock.toLowerCase()}.'
        : filipino
        ? 'Ito ang gamot mo sa ${_filipinoPeriod(period)}.'
        : 'Here are your ${period.toLowerCase()} medicines.';
    if (items.isEmpty) {
      return filipino
          ? '$intro Wala kang nakatakdang gamot.'
          : '$intro No medicines are scheduled.';
    }
    return '$intro ${items.join(', ')}.';
  }

  String? _expiryReadout(Medication medication, {required bool filipino}) {
    if (!medication.isExpired && !medication.isExpiringSoon) return null;
    final expirationDate = medication.expirationDate;
    final daysUntilExpiry = medication.daysUntilExpiry;
    if (expirationDate == null || daysUntilExpiry == null) return null;
    final date = MedicineExpiryParser.formatStored(expirationDate);
    if (medication.isExpired) {
      return filipino
          ? 'expired na noong $date, huwag inumin'
          : 'expired on $date, do not take it';
    }
    if (daysUntilExpiry == 0) {
      return filipino
          ? 'mag-e-expire ngayong araw, $date'
          : 'expires today, $date';
    }
    if (daysUntilExpiry == 1) {
      return filipino ? 'mag-e-expire bukas, $date' : 'expires tomorrow, $date';
    }
    return filipino
        ? 'mag-e-expire sa loob ng $daysUntilExpiry araw, sa $date'
        : 'expires in $daysUntilExpiry days, on $date';
  }

  String _filipinoPeriod(String period) => switch (period) {
    'Morning' => 'umaga',
    'Afternoon' => 'hapon',
    'Evening' => 'gabi',
    'Night' => 'oras ng pagtulog',
    _ => period.toLowerCase(),
  };

  (String, String) _nextDoseReadout() {
    final pending = <({Medication med, ScheduleTime time})>[];
    for (final med in _medications?.medications ?? <Medication>[]) {
      for (final time in med.schedule) {
        if (!time.taken) pending.add((med: med, time: time));
      }
    }
    if (pending.isEmpty) {
      return (
        'You have no pending medicine today.',
        'Wala ka nang gamot na kailangang inumin ngayong araw.',
      );
    }
    pending.sort(
      (a, b) => (a.time.time.hour * 60 + a.time.time.minute).compareTo(
        b.time.time.hour * 60 + b.time.time.minute,
      ),
    );
    final now = DateTime.now();
    final minuteNow = now.hour * 60 + now.minute;
    final upcoming = pending.where(
      (item) => item.time.time.hour * 60 + item.time.time.minute >= minuteNow,
    );
    final next = upcoming.isNotEmpty ? upcoming.first : pending.first;
    final overdue = upcoming.isEmpty;
    final medicine = [
      _spokenName(next.med),
      MedicineSpeechFormatter.strength(next.med.dosage),
    ].where((part) => part.isNotEmpty).join(', ');
    return overdue
        ? (
            'Your next pending medicine is overdue: $medicine, scheduled at ${next.time.formattedTime}.',
            'Lampas na sa oras ang susunod mong gamot: $medicine, nakatakda sa ${next.time.formattedTime}.',
          )
        : (
            'Your next medicine is $medicine at ${next.time.formattedTime}.',
            'Ang susunod mong gamot ay $medicine, sa ${next.time.formattedTime}.',
          );
  }

  // ------------------------------------------------------- guided scan answer

  /// Guided MediScan prompts use Vosk for a single bounded answer. They do not
  /// dispatch navigation commands or start any other speech engine, and the
  /// answer is validated by the caller: the bundled model is a static graph, so
  /// there is no runtime grammar to narrow the recognizer.
  Future<String?> listenForScanAnswer({
    Duration duration = const Duration(seconds: 8),
  }) async {
    if (_disposed ||
        !_isForeground ||
        !_pushToTalkMode ||
        _analysisPauseCount > 0 ||
        _commandSessionActive) {
      return null;
    }
    final listener = _listener;
    if (listener == null) return null;
    // A guided answer must not race the idle wake poll for the microphone.
    final resumeWake = await _suspendWakeWord();
    _processing = true;
    _listening = true;
    try {
      final answer = listener.listenForTranscript(
        baseTimeout: duration,
        // A short phrase such as "alas siyete ng gabi" may arrive in several
        // partial chunks. Keep the guided session alive through natural
        // pauses between those chunks before treating them as silence.
        partialExtension: const Duration(seconds: 3),
      );
      _activeScanAnswer = answer;
      notifyListeners();
      return await answer;
    } finally {
      _activeScanAnswer = null;
      _processing = false;
      _listening = false;
      if (resumeWake) _releaseWakeWord();
      notifyListeners();
    }
  }

  /// Gives an active guided scan answer more time without stopping the mic or
  /// starting a competing navigation session.
  bool extendScanAnswerListening({
    Duration timeout = const Duration(seconds: 12),
  }) {
    if (_activeScanAnswer == null) return false;
    final extended = _listener?.extendCurrentSession(timeout) ?? false;
    if (extended) notifyListeners();
    return extended;
  }

  /// Finish a guided answer before opening the next medicine's prompt.
  Future<void> stopScanAnswer() async {
    await _listener?.stop();
    final active = _activeScanAnswer;
    if (active != null) {
      await active;
    }
  }

  // ------------------------------------------------------------- confirmations

  void confirmTake(({Medication med, ScheduleTime s}) dose) {
    if (_prompt is! _TakePrompt) return;
    _rememberUndoableTake(dose);
    _prompt = null;
    notifyListeners();
    unawaited(
      _medications?.toggleDoseStatus(dose.med.id, dose.s.id, true) ??
          Future<void>.value(),
    );
  }

  void cancelTake() {
    if (_prompt is! _TakePrompt) return;
    _prompt = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _wakeArmed = false;
    _wakeLoop = null;
    final released = _navigationPauseReleased;
    _navigationPauseReleased = null;
    if (released != null && !released.isCompleted) released.complete();
    final idle = _voiceInteractionIdle;
    _voiceInteractionIdle = null;
    if (idle != null && !idle.isCompleted) idle.complete();
    _prompt = null;
    _undoableTakes.clear();
    WidgetsBinding.instance.removeObserver(this);
    _modelStore.cancel();
    _modelStore.dispose();
    // Avoid native channel calls after the Flutter engine starts detaching.
    _listener?.detach();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _isForeground = true;
        if (_pushToTalkMode) enableWakeWord();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _isForeground = false;
        unawaited(stopListening());
      case AppLifecycleState.detached:
        _isForeground = false;
        _suppressNoMatchFeedback = true;
        _disposed = true;
        _wakeArmed = false;
        _wakeLoop = null;
        _listening = false;
        _processing = false;
        _commandSessionActive = false;
        _listener?.detach();
        _tts?.detach();
    }
  }

  void _notifyIfActive() {
    if (!_disposed) notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }
}
