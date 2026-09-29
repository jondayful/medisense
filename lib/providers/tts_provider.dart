import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

enum AppLanguage { english, filipino }

class TtsProvider extends ChangeNotifier {
  final FlutterTts _flutterTts = FlutterTts();
  AppLanguage _language = AppLanguage.filipino;
  double _speechRate = 1.0;
  double _pitch = 1.0;
  double _volume = 1.0;

  bool _isSpeaking = false;
  bool _disposed = false;
  bool get isSpeaking => _isSpeaking;
  _SpeechRequest? _activeSpeech;
  Future<void> _speechControlTail = Future<void>.value();
  int _speechGeneration = 0;
  late final Future<void> _initialization;

  AppLanguage get language => _language;

  String _lastEnglishText = '';
  String _lastFilipinoText = '';

  /// The text of the most recent utterance in the active language — shown as
  /// a caption so partially-sighted users can read what is being spoken.
  String? get lastSpoken => _language == AppLanguage.filipino
      ? (_lastFilipinoText.isEmpty ? null : _lastFilipinoText)
      : (_lastEnglishText.isEmpty ? null : _lastEnglishText);

  final void Function()? onCompleteCallback;
  TtsProvider({this.onCompleteCallback}) {
    _initialization = _initTts();
  }

  Future<void> _initTts() async {
    await _updateTtsLanguage();
    if (_disposed) return;
    await _applyVoiceSettings();
    if (_disposed) return;
    await _flutterTts.awaitSpeakCompletion(true);
    if (_disposed) return;

    _flutterTts.setStartHandler(() {
      if (_disposed) return;
      // Android may deliver a delayed start event after an explicit stop.
      if (_activeSpeech == null) return;
      _isSpeaking = true;
      notifyListeners();
    });

    _flutterTts.setCompletionHandler(() {
      if (_disposed) return;
      _completeActiveSpeech();
    });

    _flutterTts.setCancelHandler(() {
      // Cancellation is expected only after [stop] has already cleared the
      // active request. Do not release the guard here: Android can emit a
      // stale cancel callback from an older utterance.
    });

    _flutterTts.setErrorHandler((msg) {
      if (_disposed) return;
      _failActiveSpeech(StateError('TTS error: $msg'));
    });
  }

  Future<void> setSpeechRate(double rate) async {
    if (_disposed) return;
    _speechRate = rate.clamp(0.5, 1.5).toDouble();
    // FlutterTts uses 0.5 as its normal Android engine rate. Keep the app's
    // 1.0x label intuitive by translating the user-facing multiplier first.
    try {
      await _flutterTts.setSpeechRate(_speechRate * 0.5);
    } catch (error) {
      debugPrint('TTS speech rate update failed: $error');
    }
  }

  Future<void> setPitch(double pitch) async {
    if (_disposed) return;
    _pitch = pitch.clamp(0.5, 2.0).toDouble();
    try {
      await _flutterTts.setPitch(_pitch);
    } catch (error) {
      debugPrint('TTS pitch update failed: $error');
    }
  }

  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    _volume = volume.clamp(0.0, 1.0).toDouble();
    try {
      await _flutterTts.setVolume(_volume);
    } catch (error) {
      debugPrint('TTS volume update failed: $error');
    }
  }

  Future<void> _applyVoiceSettings() async {
    if (_disposed) return;
    await _flutterTts.setSpeechRate(_speechRate * 0.5);
    await _flutterTts.setVolume(_volume);
    await _flutterTts.setPitch(_pitch);
  }

  Future<void> _updateTtsLanguage() async {
    if (_disposed) return;
    final code = _language == AppLanguage.filipino ? "fil-PH" : "en-US";

    final isSupported = await _flutterTts.isLanguageAvailable(code);
    if (_disposed) return;
    if (isSupported) {
      await _flutterTts.setLanguage(code);
    } else if (_language == AppLanguage.filipino) {
      await _flutterTts.setLanguage("tl-PH");
    }
  }

  void setLanguage(AppLanguage lang) async {
    if (_disposed) return;
    _language = lang;
    try {
      await _updateTtsLanguage();
    } catch (error) {
      debugPrint('TTS language change failed: $error');
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> speak(String englishText, String filipinoText) async {
    await _enqueueSpeech(englishText, filipinoText);
  }

  /// Plays a short interface cue without replacing the last meaningful
  /// message used by [repeatLast].
  Future<void> speakCue(String englishText, String filipinoText) async {
    await _enqueueSpeech(englishText, filipinoText, rememberAsLast: false);
  }

  /// Alarm speech deliberately uses the device TTS engine at full volume.
  /// Notification-channel volume remains under the user's OS controls, but
  /// this ensures the full-screen accessible reminder is never softened by a
  /// previously selected in-app voice-preview volume.
  Future<void> speakAlarm(String englishText, String filipinoText) async {
    await _enqueueSpeech(englishText, filipinoText, alarm: true);
  }

  Future<void> repeatLast() async {
    if (_lastEnglishText.isEmpty && _lastFilipinoText.isEmpty) return;
    await speak(_lastEnglishText, _lastFilipinoText);
  }

  Future<void> stop() async {
    if (_disposed) return;
    ++_speechGeneration;
    await _serializeSpeechControl(() async {
      if (_disposed) return;
      final hadActiveSpeech = _activeSpeech != null;
      // Clear Dart state before crossing the platform channel: Android can
      // deliver a delayed completion callback after stop has been requested.
      _clearSpeechQueue();
      if (hadActiveSpeech) await _stopNativeSpeech();
    });
  }

  @override
  void dispose() {
    detach();
    super.dispose();
  }

  /// Ends Dart callbacks and queued utterances without calling the TTS
  /// platform channel. Used when the host Flutter engine is detaching.
  void detach() {
    if (_disposed) return;
    _disposed = true;
    ++_speechGeneration;
    _clearSpeechQueue(notify: false);
    // Do not send a platform-channel stop while Flutter is detaching its
    // engine. Android releases the synthesizer with the Activity/service.
    _flutterTts.setStartHandler(() {});
    _flutterTts.setCompletionHandler(() {});
    _flutterTts.setCancelHandler(() {});
    _flutterTts.setErrorHandler((_) {});
  }

  Future<void> _enqueueSpeech(
    String englishText,
    String filipinoText, {
    bool alarm = false,
    bool rememberAsLast = true,
  }) {
    if (_disposed) return Future<void>.value();
    final text = _language == AppLanguage.filipino ? filipinoText : englishText;
    if (text.isEmpty) return Future<void>.value();
    if (rememberAsLast) {
      _lastEnglishText = englishText;
      _lastFilipinoText = filipinoText;
    }
    final request = _SpeechRequest(englishText, filipinoText, alarm: alarm);
    final generation = ++_speechGeneration;
    unawaited(
      _serializeSpeechControl(() async {
        if (_disposed || generation != _speechGeneration) {
          _completeRequest(request);
          return;
        }

        final hadActiveSpeech = _activeSpeech != null;
        // Screen changes and new prompts supersede stale speech. There is no
        // FIFO backlog: only the most recently requested utterance is relevant.
        _clearSpeechQueue();
        if (hadActiveSpeech) await _stopNativeSpeech();
        if (_disposed || generation != _speechGeneration) {
          _completeRequest(request);
          return;
        }

        _activeSpeech = request;
        _isSpeaking = true;
        notifyListeners();
        unawaited(_speakActiveRequest(request));
      }),
    );
    return request.done.future;
  }

  Future<void> _serializeSpeechControl(Future<void> Function() action) {
    final operation = _speechControlTail.then((_) => action());
    _speechControlTail = operation.catchError((Object error, StackTrace stack) {
      debugPrint('TTS control operation failed: $error');
    });
    return _speechControlTail;
  }

  Future<void> _stopNativeSpeech() async {
    try {
      await _initialization;
      if (!_disposed) await _flutterTts.stop();
    } catch (error) {
      // Android can unbind its TTS service while the app is backgrounding.
      debugPrint('TTS stop skipped after engine disconnect: $error');
    }
  }

  void _completeRequest(_SpeechRequest request) {
    if (!request.done.isCompleted) request.done.complete();
  }

  Future<void> _speakActiveRequest(_SpeechRequest request) async {
    try {
      await _initialization;
      if (_disposed || !identical(_activeSpeech, request)) return;
      if (Platform.isIOS) {
        // Speech recognition uses the shared AVAudioSession for input. Restore
        // an output category for every utterance, including the first prompt
        // after a voice command and each repeat of an opened dose alarm.
        await _flutterTts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playback,
          const [IosTextToSpeechAudioCategoryOptions.duckOthers],
        );
      }
      if (_disposed || !identical(_activeSpeech, request)) return;
      await _updateTtsLanguage();
      if (_disposed || !identical(_activeSpeech, request)) return;
      if (request.alarm) {
        await _flutterTts.setVolume(1.0);
        await _flutterTts.setSpeechRate(0.42);
        await _flutterTts.setPitch(_pitch);
      } else {
        await _applyVoiceSettings();
      }
      if (_disposed || !identical(_activeSpeech, request)) return;
      final text = _language == AppLanguage.filipino
          ? request.filipinoText
          : request.englishText;
      await _flutterTts.speak(text);
    } catch (error) {
      _failActiveSpeech(error);
    }
  }

  void _completeActiveSpeech() {
    if (_disposed) return;
    final request = _activeSpeech;
    if (request == null) return;
    _activeSpeech = null;
    _isSpeaking = false;
    if (!request.done.isCompleted) request.done.complete();
    onCompleteCallback?.call();
    notifyListeners();
  }

  void _failActiveSpeech(Object error) {
    if (_disposed) return;
    final request = _activeSpeech;
    if (request == null) return;
    _activeSpeech = null;
    _isSpeaking = false;
    if (!request.done.isCompleted) request.done.complete();
    debugPrint('TTS request failed: $error');
    notifyListeners();
  }

  void _clearSpeechQueue({bool notify = true}) {
    final active = _activeSpeech;
    _activeSpeech = null;
    _isSpeaking = false;
    if (active != null && !active.done.isCompleted) active.done.complete();
    if (notify && !_disposed) notifyListeners();
  }
}

class _SpeechRequest {
  _SpeechRequest(this.englishText, this.filipinoText, {required this.alarm});

  final String englishText;
  final String filipinoText;
  final bool alarm;
  final Completer<void> done = Completer<void>();
}
