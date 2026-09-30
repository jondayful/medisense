import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as path;
import 'package:vosk_flutter/vosk_flutter.dart';

import 'vosk_command_dispatcher.dart';

/// Uses Vosk on Android and on-device system speech on iOS for short commands.
///
/// [VoskModelStore] owns the Android model download/extraction; this class
/// consumes its validated path or iOS's system speech sentinel.
class VoskCommandListener {
  VoskCommandListener({
    required this.onCommand,
    this.onPartial,
    this.onFinalText,
    this.iosLocale,
    VoskCommandDispatcher? dispatcher,
  }) : _dispatcher = dispatcher ?? const VoskCommandDispatcher();

  static const sampleRate = 16000;
  // A long instruction such as "move Biogesic to eight in the morning" needs
  // more room than a one-word answer. The window is a floor; any decoded
  // partial extends it further, so this only has to cover the first pause.
  static const baseSilenceTimeout = Duration(seconds: 8);
  static const partialSpeechExtension = Duration(seconds: 3);
  static const fastCommandSettle = Duration(milliseconds: 700);
  static const preferredTranscriptSettle = Duration(milliseconds: 450);
  static const audioReleaseSettle = Duration(milliseconds: 150);
  static const _voskChannel = MethodChannel('vosk_flutter');
  static const _iosSpeechChannel = MethodChannel('medisense/ios_speech');

  final VoskCommandDispatcher _dispatcher;
  final FutureOr<void> Function(VoskCommand command) onCommand;
  final ValueChanged<String>? onPartial;
  final ValueChanged<String>? onFinalText;
  final String Function()? iosLocale;

  // Delay plugin construction: its current microphone implementation is
  // Android-only, so merely constructing this class remains safe on iOS.
  late final VoskFlutterPlugin _vosk;
  Model? _model;
  Recognizer? _recognizer;
  SpeechService? _speechService;
  bool _iosReady = false;
  StreamSubscription<String>? _partialSubscription;
  StreamSubscription<String>? _resultSubscription;
  Future<void>? _initialization;
  Future<void>? _stopOperation;
  Future<void>? _startOperation;
  int _startGeneration = 0;
  Timer? _silenceTimer;
  Timer? _partialDispatchTimer;
  Timer? _preferredTranscriptTimer;
  Completer<String?>? _sessionCompleter;
  Duration _partialTimeout = partialSpeechExtension;
  bool _dispatchCommands = true;
  bool Function(String text)? _preferTranscript;
  bool _commandInFlight = false;
  bool _isListening = false;
  bool _disposed = false;
  String _lastDispatched = '';
  String _lastPartialText = '';
  DateTime _lastDispatchAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isListening => _isListening;

  /// Keeps the current guided answer session open for a little longer after a
  /// user explicitly taps the in-sheet microphone control.
  bool extendCurrentSession(Duration timeout) {
    if (_disposed || !_isListening || _sessionCompleter == null) return false;
    _armSilenceTimeout(timeout);
    return true;
  }

  /// [absoluteModelPath] is the validated Android model or iOS speech sentinel
  /// supplied by [VoskModelStore]. This listener never downloads a model.
  Future<void> initialize(String absoluteModelPath) {
    if (_disposed) {
      return Future<void>.error(StateError('Vosk listener has been disposed.'));
    }
    if (_speechService != null || _iosReady) return Future<void>.value();
    final pending = _initialization;
    if (pending != null) return pending;
    final future = _initialize(absoluteModelPath);
    _initialization = future;
    return future.whenComplete(() {
      if (identical(_initialization, future)) _initialization = null;
    });
  }

  Future<void> _initialize(String absoluteModelPath) async {
    if (!path.isAbsolute(absoluteModelPath)) {
      throw ArgumentError.value(
        absoluteModelPath,
        'absoluteModelPath',
        'Must be absolute.',
      );
    }
    if (Platform.isIOS) {
      _iosSpeechChannel.setMethodCallHandler((call) async {
        if (_disposed) return;
        final text = call.arguments as String? ?? '';
        if (call.method == 'partial') {
          _handlePartial(jsonEncode({'partial': text}));
        } else if (call.method == 'result') {
          await _handleResult(jsonEncode({'text': text}));
        } else if (call.method == 'error') {
          debugPrint('iOS speech recognition failed: $text');
          final session = _sessionCompleter;
          await stop(completeSession: false);
          if (session != null && !session.isCompleted) {
            session.completeError(
              PlatformException(
                code: 'SPEECH_RUNTIME',
                message: text.isEmpty
                    ? 'Speech recognition stopped unexpectedly.'
                    : text,
              ),
            );
          }
        }
      });
      _iosReady = true;
      return;
    }
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'vosk_flutter microphone capture is Android-only.',
      );
    }
    _vosk = VoskFlutterPlugin.instance();

    try {
      _model = await _vosk.createModel(absoluteModelPath);
      _recognizer = await _vosk.createRecognizer(
        model: _model!,
        sampleRate: sampleRate,
        // vosk-model-tl-ph-generic-0.6 is a static-graph model. Passing a
        // grammar makes Vosk attempt a runtime graph and fails on Android.
      );
      // Keep a small N-best list. If Vosk's first guess misses a command word,
      // the dispatcher can still use a valid second or third candidate.
      await _recognizer!.setMaxAlternatives(3);
      _speechService = await _initSpeechServiceWithRecovery();
      _partialSubscription = _speechService!.onPartial().listen(_handlePartial);
      _resultSubscription = _speechService!.onResult().listen(_handleResult);
    } catch (_) {
      await _partialSubscription?.cancel();
      await _resultSubscription?.cancel();
      await _speechService?.dispose();
      await _recognizer?.dispose();
      _model?.dispose();
      _partialSubscription = null;
      _resultSubscription = null;
      _speechService = null;
      _recognizer = null;
      _model = null;
      rethrow;
    }
  }

  Future<SpeechService> _initSpeechServiceWithRecovery() async {
    try {
      return await _vosk.initSpeechService(_recognizer!);
    } on PlatformException catch (error) {
      final message = '${error.code} ${error.message}'.toLowerCase();
      if (!message.contains('speechservice') ||
          !message.contains('already exist')) {
        rethrow;
      }

      // A hot restart or an interrupted previous initialization can leave the
      // plugin's process-global Android service alive while Dart has lost its
      // wrapper. This provider is the sole owner, so safely clear and retry.
      try {
        await _voskChannel.invokeMethod<void>('speechService.destroy');
      } catch (_) {
        // If the native service disappeared between calls, the retry below is
        // still the correct recovery path.
      }
      return _vosk.initSpeechService(_recognizer!);
    }
  }

  Future<void> start({String? absoluteModelPath}) {
    final pending = _startOperation;
    if (pending != null) return pending;
    final generation = _startGeneration;
    final previousStop = _stopOperation;
    final operation = _startInternal(
      absoluteModelPath,
      generation,
      previousStop,
    );
    _startOperation = operation;
    return operation.whenComplete(() {
      if (identical(_startOperation, operation)) _startOperation = null;
    });
  }

  Future<void> _startInternal(
    String? absoluteModelPath,
    int generation,
    Future<void>? previousStop,
  ) async {
    if (_disposed) throw StateError('Vosk listener has been disposed.');
    await previousStop;
    if (_speechService == null && !_iosReady) {
      if (absoluteModelPath == null) {
        throw StateError(
          'Initialize Vosk with an absolute model path before starting.',
        );
      }
      await initialize(absoluteModelPath);
    }
    await ensureMicrophonePermission();
    if (_disposed || generation != _startGeneration) {
      throw StateError('Voice session was cancelled.');
    }
    if (_isListening) return;
    if (Platform.isIOS) {
      _isListening = true;
      try {
        await _iosSpeechChannel.invokeMethod<void>('start', {
          'locale': iosLocale?.call() ?? 'en-PH',
        });
      } catch (_) {
        _isListening = false;
        rethrow;
      }
      return;
    }
    await _speechService!.start();
    _isListening = true;
  }

  Future<void> ensureMicrophonePermission() async {
    if (Platform.isIOS) {
      await _iosSpeechChannel.invokeMethod<void>('prepare');
      return;
    }
    var permission = await Permission.microphone.status;
    if (!permission.isGranted) {
      permission = await Permission.microphone.request();
    }
    if (!permission.isGranted) {
      throw StateError(
        'Microphone permission is required for offline commands.',
      );
    }
  }

  /// Starts a bounded command session. The first utterance has
  /// [baseSilenceTimeout] to begin speaking. Each non-empty partial result
  /// resets the deadline to [partialExtension], so a slow speaker is not cut
  /// off while Vosk continues detecting speech.
  Future<bool> listenForCommand({
    Duration baseTimeout = baseSilenceTimeout,
    Duration partialExtension = partialSpeechExtension,
  }) async {
    final text = await _listen(
      baseTimeout: baseTimeout,
      partialExtension: partialExtension,
      dispatchCommands: true,
    );
    return text != null;
  }

  /// Captures a single final utterance.
  Future<String?> listenForTranscript({
    Duration baseTimeout = baseSilenceTimeout,
    Duration partialExtension = partialSpeechExtension,
    bool Function(String text)? preferTranscript,
  }) {
    return _listen(
      baseTimeout: baseTimeout,
      partialExtension: partialExtension,
      dispatchCommands: false,
      preferTranscript: preferTranscript,
    );
  }

  Future<String?> _listen({
    required Duration baseTimeout,
    required Duration partialExtension,
    required bool dispatchCommands,
    bool Function(String text)? preferTranscript,
  }) async {
    if (_sessionCompleter != null) {
      throw StateError('A Vosk command session is already active.');
    }
    if (_recognizer == null && !_iosReady) {
      throw StateError('Initialize Vosk before starting a command session.');
    }
    final completer = _sessionCompleter = Completer<String?>();
    try {
      _partialTimeout = partialExtension;
      _dispatchCommands = dispatchCommands;
      _preferTranscript = preferTranscript;
      _lastPartialText = '';
      await start();
      _armSilenceTimeout(baseTimeout);
      return await completer.future;
    } finally {
      if (identical(_sessionCompleter, completer)) {
        _sessionCompleter = null;
      }
      await stop(completeSession: false);
      try {
        if (!_disposed) await _recognizer?.reset();
      } finally {
        _dispatchCommands = true;
        _preferTranscript = null;
      }
    }
  }

  /// Awaits the native stop acknowledgement, then leaves a short hardware
  /// settle window before a caller starts TTS. `vosk_flutter` does not expose
  /// Android's AudioFocus callbacks; an awaited stop is its release signal.
  Future<void> stop({bool completeSession = true}) async {
    ++_startGeneration;
    if (_disposed) {
      _silenceTimer?.cancel();
      _partialDispatchTimer?.cancel();
      _isListening = false;
      if (completeSession) _completeSession(null);
      return;
    }
    final currentStop = _stopOperation;
    if (currentStop != null) {
      await currentStop;
      if (completeSession) _completeSession(null);
      return;
    }
    final operation = _stopInternal(completeSession: completeSession);
    _stopOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_stopOperation, operation)) _stopOperation = null;
    }
  }

  Future<void> _stopInternal({required bool completeSession}) async {
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _partialDispatchTimer?.cancel();
    _partialDispatchTimer = null;
    try {
      await _startOperation;
    } catch (_) {
      // An interrupted permission request or cancelled start still needs the
      // session completer below to be released.
    }
    final wasListening = _isListening;
    _isListening = false;
    try {
      if (wasListening) {
        if (Platform.isIOS) {
          await _iosSpeechChannel.invokeMethod<void>('stop');
        } else {
          await _speechService?.stop();
        }
        // Android's AudioRecord teardown can complete slightly after the
        // method-channel reply. Give audio focus time to settle before TTS.
        await Future<void>.delayed(audioReleaseSettle);
      }
    } catch (error) {
      debugPrint('Vosk microphone stop failed during shutdown: $error');
    } finally {
      if (completeSession) _completeSession(null);
    }
  }

  void _handlePartial(String json) {
    if (_disposed || !_isListening) return;
    final text = _textFrom(json, 'partial');
    if (text.isEmpty) return;
    _lastPartialText = text;
    // Any decoded partial means speech is still arriving, including filler
    // represented as `[unk]`; only continuous silence should time out.
    _armSilenceTimeout(_partialTimeout);
    if (text != '[unk]') onPartial?.call(text);
    _partialDispatchTimer?.cancel();
    _preferredTranscriptTimer?.cancel();
    final preferTranscript = _preferTranscript;
    if (!_dispatchCommands &&
        preferTranscript != null &&
        preferTranscript(text)) {
      // Wake phrases should activate on Vosk's stable partial transcript; many
      // models emit no final result until much later or only on silence.
      _preferredTranscriptTimer = Timer(preferredTranscriptSettle, () {
        if (!_disposed &&
            _isListening &&
            !_dispatchCommands &&
            _lastPartialText == text &&
            identical(_preferTranscript, preferTranscript)) {
          onFinalText?.call(text);
          unawaited(_completePreferredTranscript(text));
        }
      });
    }
    if (_dispatchCommands && !_commandInFlight) {
      final command = _dispatcher.dispatch(text);
      if (command != null && _canDispatchFromPartial(command)) {
        // Vosk's final endpoint can take a few seconds on some devices. Once
        // a specific command remains unchanged briefly, act on it directly.
        _partialDispatchTimer = Timer(fastCommandSettle, () {
          if (!_disposed &&
              _isListening &&
              !_commandInFlight &&
              _lastPartialText == text) {
            unawaited(_dispatchRecognizedCommand(command, text));
          }
        });
      }
    }
  }

  Future<void> _completePreferredTranscript(String text) async {
    await stop(completeSession: false);
    _completeSession(text);
  }

  Future<void> _handleResult(String json) async {
    if (_disposed || !_isListening) return;
    final alternatives = _resultTexts(json);
    var text = alternatives.isEmpty ? '' : alternatives.first;
    _partialDispatchTimer?.cancel();
    _partialDispatchTimer = null;
    _preferredTranscriptTimer?.cancel();
    _preferredTranscriptTimer = null;
    _lastPartialText = '';
    if (!_dispatchCommands) {
      final preferred = _preferTranscript;
      if (preferred != null) {
        text = alternatives.firstWhere(preferred, orElse: () => text);
      }
      if (text.isNotEmpty) onFinalText?.call(text);
      await stop(completeSession: false);
      _completeSession(text.isEmpty ? null : text);
      return;
    }
    VoskCommand? command;
    // Try every alternative, not just the first that matches. A top guess can
    // carry the right verb but garble the medicine name; a lower-ranked
    // alternative often names it cleanly.
    command = _dispatcher.dispatchAny(alternatives);
    if (alternatives.isNotEmpty) text = alternatives.first;
    if (text.isNotEmpty) onFinalText?.call(text);
    if (command == null || _isDuplicate(text) || _commandInFlight) return;
    await _dispatchRecognizedCommand(command, text);
  }

  Future<void> _dispatchRecognizedCommand(
    VoskCommand command,
    String text,
  ) async {
    if (_disposed || _commandInFlight || !_isListening) return;
    _commandInFlight = true;
    _lastDispatched = text;
    _lastDispatchAt = DateTime.now();
    // Stop and settle before the provider navigates and starts local TTS.
    await stop(completeSession: false);
    try {
      await onCommand(command);
      _completeSession(text);
    } catch (_) {
      _completeSession(null);
      rethrow;
    } finally {
      _commandInFlight = false;
    }
  }

  bool _isDuplicate(String text) =>
      text == _lastDispatched &&
      DateTime.now().difference(_lastDispatchAt) < const Duration(seconds: 2);

  bool _canDispatchFromPartial(VoskCommand command) =>
      command.intent != VoskVoiceIntent.medicationSchedule &&
      command.intent != VoskVoiceIntent.markTaken &&
      command.intent != VoskVoiceIntent.removeMedication &&
      command.intent != VoskVoiceIntent.rescheduleMedication;

  void _armSilenceTimeout(Duration timeout) {
    _silenceTimer?.cancel();
    _partialDispatchTimer?.cancel();
    _preferredTranscriptTimer?.cancel();
    _silenceTimer = Timer(timeout, () => unawaited(_endForSilence()));
  }

  Future<void> _endForSilence() async {
    final fallback = _dispatchCommands
        ? _dispatcher.dispatch(_lastPartialText)
        : null;
    final transcript = _lastPartialText;
    _lastPartialText = '';
    if (transcript.isNotEmpty) onFinalText?.call(transcript);
    await stop(completeSession: false);
    if (fallback != null && !_commandInFlight && _sessionCompleter != null) {
      _commandInFlight = true;
      try {
        await onCommand(fallback);
        _completeSession(transcript);
      } catch (_) {
        _completeSession(null);
      } finally {
        _commandInFlight = false;
      }
      return;
    }
    // Guided scan answers don't use the navigation dispatcher. Vosk often
    // emits its best transcript as a partial and then stays silent instead of
    // producing a final result, so return that partial to the caller here.
    _completeSession(
      !_dispatchCommands && transcript.isNotEmpty ? transcript : null,
    );
  }

  void _completeSession(String? result) {
    final session = _sessionCompleter;
    if (session != null && !session.isCompleted) session.complete(result);
  }

  String _textFrom(String source, String field) {
    try {
      final json = jsonDecode(source) as Map<String, dynamic>;
      return (json[field] as String? ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  List<String> _resultTexts(String source) {
    try {
      final json = jsonDecode(source) as Map<String, dynamic>;
      final results = <String>[];
      final direct = (json['text'] as String? ?? '').trim();
      if (direct.isNotEmpty) results.add(direct);
      final alternatives = json['alternatives'];
      if (alternatives is List) {
        for (final item in alternatives.whereType<Map>()) {
          final text = (item['text'] as String? ?? '').trim();
          if (text.isNotEmpty && !results.contains(text)) results.add(text);
        }
      }
      return results;
    } catch (_) {
      return const [];
    }
  }

  /// Call from the owning provider/widget's dispose method.
  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    if (Platform.isIOS) _iosSpeechChannel.setMethodCallHandler(null);
    _silenceTimer?.cancel();
    await _partialSubscription?.cancel();
    await _resultSubscription?.cancel();
    await _speechService?.dispose();
    await _recognizer?.dispose();
    _model?.dispose();
  }

  /// Marks the listener inactive without sending channel calls while Flutter
  /// is destroying its engine. The operating system will release its audio
  /// service with the host Activity.
  void detach() {
    if (_disposed) return;
    _disposed = true;
    _silenceTimer?.cancel();
    _partialDispatchTimer?.cancel();
    _preferredTranscriptTimer?.cancel();
    _completeSession(null);
    _sessionCompleter = null;
    _isListening = false;
  }
}
