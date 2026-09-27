import 'package:camera/camera.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/tts_provider.dart';
import '../providers/voice_navigation_provider.dart';
import '../services/medicine_label_parser.dart';
import '../data/database_helper.dart';
import '../services/medicine_speech_formatter.dart';
import '../services/medicine_expiry_parser.dart';
import '../services/scan_speech_parser.dart';
import '../services/scan_pipeline.dart';
import '../services/accessibility_feedback.dart';
import '../services/greeting_name.dart';
import '../models/medication.dart';
import '../models/dosage.dart';
import '../models/accessibility_mode.dart';
import '../theme/app_theme.dart';
import '../providers/app_state_provider.dart';
import '../providers/medication_provider.dart';
import '../services/prescription_safety.dart';
import '../services/ph_drug_catalog.dart';
import '../services/ocr_text_cleanup.dart';
import '../services/camera_ocr_stream_service.dart';
import '../services/ocr_coordinator_service.dart';
import '../widgets/add_medication_modal.dart';
import '../widgets/elder_bottom_nav.dart';
import '../widgets/medi_bottom_nav.dart';

import '../widgets/model_download_sheet.dart';

class MediScanScreen extends StatefulWidget {
  const MediScanScreen({super.key});

  @override
  State<MediScanScreen> createState() => _MediScanScreenState();
}

enum _MedicineDecision { yes, no, edit }

/// Routes taps on the in-sheet mic control to the currently active answer
/// session. A tap during capture extends the timeout; a tap between captures
/// requests another capture.
class _GuidedMicGate {
  _GuidedMicGate(this.voice);

  final VoiceNavigationProvider voice;
  Completer<void>? _waitingForTap;
  bool _tapPending = false;

  void tap() {
    if (voice.extendScanAnswerListening()) return;
    final waiting = _waitingForTap;
    if (waiting != null && !waiting.isCompleted) {
      waiting.complete();
    } else {
      _tapPending = true;
    }
  }

  Future<bool> waitForTapOr<T>(Future<T> finished) async {
    if (_tapPending) {
      _tapPending = false;
      return true;
    }
    final waiting = _waitingForTap = Completer<void>();
    final tapped = await Future.any<bool>([
      waiting.future.then((_) => true),
      finished.then((_) => false),
    ]);
    if (identical(_waitingForTap, waiting)) _waitingForTap = null;
    return tapped;
  }
}

class _MediScanScreenState extends State<MediScanScreen>
    with WidgetsBindingObserver {
  // CameraX device close/open is asynchronous. Serialize it across screen
  // instances so a newly pushed scan screen cannot reopen a still-closing
  // device from the previous route.
  static Future<void> _cameraTransition = Future<void>.value();

  static Future<void> _serializeCamera(Future<void> Function() operation) {
    final next = _cameraTransition.then((_) => operation());
    _cameraTransition = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }

  final MedicineLabelParser _labelParser = MedicineLabelParser();
  late final OcrCoordinatorService _ocrCoordinator = OcrCoordinatorService(
    parser: _labelParser,
  );
  final BarcodeScanService _barcodeScanner = BarcodeScanService();
  final ImagePreprocessor _imagePreprocessor = ImagePreprocessor();
  final OcrTextCleanup _ocrCleanup = const OcrTextCleanup();
  final ScanResultStabilityGate _scanResultGate = ScanResultStabilityGate();
  final ScanPreviewEvidence _previewEvidence = ScanPreviewEvidence();
  String? _pendingStrengthConflictName;
  final GlobalKey _previewAreaKey = GlobalKey();
  final GlobalKey _reticleKey = GlobalKey();

  CameraController? _cameraController;
  CameraOcrStreamService? _cameraOcrStream;
  Future<void>? _cameraOpenTask;
  Future<XFile>? _pictureTask;
  bool _captureCycleActive = false;
  bool _streamCapturePending = false;
  bool _imageInferenceActive = false;
  DateTime? _lastVoiceFeedbackAt;
  String? _lastVoiceFeedback;
  DateTime? _lastUnclearPromptAt;
  DateTime? _lastQuotaPromptAt;
  Future<void> _voiceFeedbackQueue = Future<void>.value();
  final Completer<void> _voiceStartupReady = Completer<void>();
  Future<void> _initialGreetingTask = Future<void>.value();
  bool _initialGreetingStarted = false;
  bool _initialGreetingFinished = false;
  bool _waitingForGreetingBeforeAutoScan = false;
  bool _cameraPreviewActive = false;
  bool _voiceStartupGateInstalled = false;
  VoiceNavigationProvider? _voiceNavigation;
  bool _screenDisposing = false;
  bool _cameraSuspended = false;
  bool _streamDetectsPrescription = false;
  DateTime? _lastCameraHintAt;
  int _cameraHintGeneration = 0;
  Future<void> _cameraHintSpeech = Future<void>.value();
  Timer? _autoScanTimer;
  Timer? _initialAutoScanTimer;
  MedicineLabelResult? _scanResult;
  bool _isFlashOn = false;
  bool _isFlashChanging = false;
  Completer<void>? _flashChangeCompleter;
  bool _hasGreeted = false;
  AuthProvider? _observedAuth;
  bool _isInitializing = true;
  bool _isScanning = false;
  bool _isGuidedFlowActive = false;
  bool _reviewingPrescription = false;
  bool _waitForManualScanAfterBatch = false;
  bool _unrecognizedAlert = false;
  double _zoomLevel = 1.0;
  String? _statusMessage;

  final Map<String, MedicineLabelResult> _labelCache = {};
  static const int _maxLabelCacheSize = 10;

  static const List<String> _guidedFrequencies = kGuidedFrequencies;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Warm the local FDA catalog while the camera initializes. Scanning still
    // works with ML Kit if the optional catalog asset cannot be loaded.
    unawaited(PhDrugCatalog.instance.ensureLoaded());
    // Import the bundled international catalog off the first frame. The OCR
    // parser uses its in-memory index; SQLite remains available for broader
    // brand/generic lookup and future catalog toggles.
    unawaited(DatabaseHelper().ensureMedicineCatalogImported());

    unawaited(_initializeCamera());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _voiceNavigation = context.read<VoiceNavigationProvider>();
    if (!_voiceStartupGateInstalled) {
      context.read<VoiceNavigationProvider>().deferVoskInitializationUntil(
        _voiceStartupReady.future,
      );
      _voiceStartupGateInstalled = true;
    }
    final auth = context.read<AuthProvider>();
    if (!identical(_observedAuth, auth)) {
      _observedAuth?.removeListener(_maybeGreet);
      _observedAuth = auth..addListener(_maybeGreet);
    }
    _maybeGreet();
    _releaseVoskStartupGateWhenReady();
  }

  void _maybeGreet() {
    if (!mounted || _hasGreeted) return;
    final auth = _observedAuth ?? context.read<AuthProvider>();
    final appState = context.read<AppStateProvider>();

    // App startup restores the persisted AuthProvider in a post-frame task.
    // Do not speak "Guest" while a saved account is waiting to be restored.
    if (appState.savedUserId != null && !auth.isLoggedIn) return;

    final tts = context.read<TtsProvider>();
    // The dashboard also uses the persisted onboarding name for local/guest
    // sessions. Use the same source here so entering Scan does not reset the
    // greeting to "Guest" while the account session is being restored.
    final name = resolveGreetingName([
      if (auth.isLoggedIn) auth.userName,
      appState.savedUserName,
      appState.onboardingName,
    ]);
    _initialGreetingStarted = true;
    _initialGreetingTask = _speakIfVoiceNavigationEnabled(
      tts,
      name == null
          ? 'Align the medicine label with the camera and wait for it to scan.'
          : 'Hello $name, align the medicine label with the camera and wait for it to scan.',
      name == null
          ? 'Itapat ang label ng gamot sa camera at hintayin itong ma-scan.'
          : 'Hello $name, itapat ang label ng gamot sa camera at hintayin itong ma-scan.',
    );
    _hasGreeted = true;
    unawaited(
      _initialGreetingTask.whenComplete(() {
        if (!mounted) return;
        _initialGreetingFinished = true;
        _releaseVoskStartupGateWhenReady();
        _startAutoScan();
      }),
    );
    _releaseVoskStartupGateWhenReady();
  }

  void _releaseVoskStartupGateWhenReady() {
    if (_voiceStartupReady.isCompleted || !_cameraPreviewActive) return;
    final voiceEnabled = context
        .read<AppStateProvider>()
        .voiceNavigationEnabled;
    if (voiceEnabled && !_initialGreetingStarted) return;
    unawaited(() async {
      await _initialGreetingTask;
      if (!_voiceStartupReady.isCompleted) _voiceStartupReady.complete();
    }());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _cameraSuspended = false;
      if (!_isGuidedFlowActive) unawaited(_initializeCamera());
      return;
    }
    _autoScanTimer?.cancel();
    _initialAutoScanTimer?.cancel();
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _cameraSuspended = true;
      unawaited(_closeCamera());
    }
  }

  @override
  void dispose() {
    _screenDisposing = true;
    if (!_voiceStartupReady.isCompleted) _voiceStartupReady.complete();
    _observedAuth?.removeListener(_maybeGreet);
    WidgetsBinding.instance.removeObserver(this);
    _autoScanTimer?.cancel();
    _initialAutoScanTimer?.cancel();
    unawaited(
      _closeCamera().whenComplete(() {
        // Camera/OCR can briefly own the microphone. Re-arm wake listening after
        // its native resources have closed when leaving Scan.
        _voiceNavigation?.enableWakeWord();
      }),
    );
    unawaited(_ocrCoordinator.dispose());
    _barcodeScanner.dispose();
    unawaited(_imagePreprocessor.dispose());
    super.dispose();
  }

  Future<void> _initializeCamera() {
    if (_screenDisposing || _cameraSuspended) return Future<void>.value();
    return _cameraOpenTask ??= _serializeCamera(_openCamera).whenComplete(() {
      _cameraOpenTask = null;
    });
  }

  Future<void> _openCamera() async {
    if (_screenDisposing || _cameraSuspended || !mounted) return;
    if (_cameraController?.value.isInitialized == true) {
      if (!_isGuidedFlowActive) _startAutoScan();
      return;
    }
    setState(() {
      _isInitializing = true;
      _statusMessage = 'Preparing camera';
    });

    PermissionStatus permission;
    try {
      permission = await Permission.camera.request();
    } catch (_) {
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _statusMessage = 'Camera permission is unavailable.';
        });
      }
      return;
    }
    if (!permission.isGranted) {
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _statusMessage = 'Camera permission is needed to read medicine labels.';
      });
      return;
    }
    if (_screenDisposing || _cameraSuspended || !mounted) return;

    CameraController? opening;
    try {
      final cameras = await availableCameras();
      final backCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      opening = CameraController(
        backCamera,
        // Camera2 maps high to a 720p profile; medium is only 480p here.
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );

      await opening.initialize();
      if (_screenDisposing || _cameraSuspended || !mounted) {
        await opening.dispose();
        return;
      }
      // Some front cameras and low-end back cameras have no flash unit. That
      // should disable torch use, not prevent the camera preview from opening.
      try {
        await opening.setFlashMode(FlashMode.off);
      } catch (_) {}
      // Camera2 maps FocusMode.auto to CONTROL_AF_MODE_CONTINUOUS_PICTURE.
      // The local Android backend preserves that repeating focus mode for
      // still captures, so automatic scans never wait for an AF-lock loop.
      await opening.setFocusMode(FocusMode.auto);
      _cameraController = opening;
      _cameraOcrStream = CameraOcrStreamService(
        camera: opening,
        onHint: _onCameraOcrHint,
        onCapture: _onCameraOcrCapture,
        onError: _onCameraOcrError,
        onText: (text) {
          final layoutText = _ocrCleanup
              .clean(_labelParser.layoutRecognizedText(text))
              .text;
          final detection = _labelParser.detectPrescriptionDocument(layoutText);
          if (!detection.isPrescription) {
            _previewEvidence.observe(detection.items);
          }
          // Require actual prescription structure. Density or a generic
          // heading alone is common on medicine packaging and should not
          // divert the normal package-label scan into full-page OCR.
          _streamDetectsPrescription = detection.isPrescription;
        },
      );
      _cameraPreviewActive = true;

      setState(() {
        _isInitializing = false;
        _statusMessage = 'Auto-reading medicine label';
        // A newly opened camera is initialized with flash off. Keep the UI in
        // sync after app lifecycle pauses and camera recreation.
        _isFlashOn = false;
      });
      // Don't start the scan timer if the guided voice flow is active —
      // the camera hardware has been released for the microphone.
      if (!_isGuidedFlowActive) _startAutoScan();
      _releaseVoskStartupGateWhenReady();
    } catch (_) {
      _cameraController = null;
      final stream = _cameraOcrStream;
      _cameraOcrStream = null;
      try {
        await stream?.dispose();
      } catch (_) {}
      try {
        await opening?.dispose();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _statusMessage = 'Camera is unavailable on this device.';
      });
    }
  }

  Future<void> _closeCamera() => _serializeCamera(() async {
    final stream = _cameraOcrStream;
    _cameraOcrStream = null;
    final controller = _cameraController;
    _cameraController = null;
    if (stream != null) {
      try {
        await stream.dispose();
      } catch (_) {}
    }
    if (controller == null) return;
    if (mounted && !_screenDisposing) {
      setState(() {
        _isInitializing = true;
        _statusMessage = 'Camera paused';
      });
    }
    try {
      await _pictureTask;
    } catch (_) {
      // A failed capture must not block device release.
    }
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {}
    try {
      await controller.dispose();
    } catch (_) {}
  });

  void _startAutoScan() {
    _autoScanTimer?.cancel();
    _initialAutoScanTimer?.cancel();
    if (_screenDisposing ||
        _cameraSuspended ||
        _isFlashChanging ||
        _captureCycleActive ||
        _streamCapturePending ||
        _scanResult != null ||
        _reviewingPrescription ||
        _waitForManualScanAfterBatch) {
      return;
    }
    final voiceEnabled = context
        .read<AppStateProvider>()
        .voiceNavigationEnabled;
    final appState = context.read<AppStateProvider>();
    final waitingForAccountRestore =
        voiceEnabled &&
        !_initialGreetingStarted &&
        !_hasGreeted &&
        appState.savedUserId != null &&
        !context.read<AuthProvider>().isLoggedIn;
    if (voiceEnabled &&
        ((_initialGreetingStarted && !_initialGreetingFinished) ||
            waitingForAccountRestore)) {
      // OCR pauses voice navigation and stops TTS to avoid microphone and
      // camera audio overlap. Wait until the greeting has actually finished
      // so the first automatic capture cannot cut it off mid-word.
      if (_initialGreetingStarted && !_waitingForGreetingBeforeAutoScan) {
        _waitingForGreetingBeforeAutoScan = true;
        unawaited(
          _initialGreetingTask.whenComplete(() {
            _waitingForGreetingBeforeAutoScan = false;
            if (!mounted) return;
            _initialGreetingFinished = true;
            _startAutoScan();
          }),
        );
      }
      return;
    }
    final stream = _cameraOcrStream;
    if (stream != null) {
      if (!stream.isRunning) unawaited(_startCameraOcrStream(stream));
      return;
    }
    _scheduleStillAutoScans();
  }

  Future<void> _startCameraOcrStream(CameraOcrStreamService stream) async {
    try {
      await stream.startStream();
    } catch (error) {
      debugPrint('MediScan: camera text stream unavailable: $error');
      try {
        await stream.stopStream();
      } catch (_) {}
      if (mounted && !_screenDisposing && !_cameraSuspended) {
        _scheduleStillAutoScans();
      }
    }
  }

  void _scheduleStillAutoScans() {
    if (_screenDisposing ||
        _cameraSuspended ||
        _reviewingPrescription ||
        _waitForManualScanAfterBatch) {
      return;
    }
    _autoScanTimer?.cancel();
    _initialAutoScanTimer?.cancel();
    _autoScanTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted &&
          !_screenDisposing &&
          !_reviewingPrescription &&
          !_isGuidedFlowActive &&
          _scanResult == null) {
        _captureAndReadLabel(automatic: true);
      }
    });
    _initialAutoScanTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted &&
          !_screenDisposing &&
          !_cameraSuspended &&
          !_captureCycleActive &&
          !_reviewingPrescription &&
          !_isGuidedFlowActive &&
          _scanResult == null) {
        _captureAndReadLabel(automatic: true);
      }
    });
  }

  void _onCameraOcrHint(ScanHint hint) {
    if (!mounted || _screenDisposing || _cameraSuspended) return;
    if (_initialGreetingStarted && !_initialGreetingFinished) return;
    final appState = context.read<AppStateProvider>();
    if (!appState.voiceNavigationEnabled ||
        appState.ttsVerbosity == TtsVerbosity.essential) {
      return;
    }
    final voice = context.read<VoiceNavigationProvider>();
    // User speech has priority over camera guidance. Repeated auto-framing
    // cues used to stop the wake listener often enough that it felt disabled.
    if (_imageInferenceActive ||
        voice.isListening ||
        voice.isProcessing ||
        voice.isScanAnswerListening) {
      return;
    }
    final now = DateTime.now();
    if (_lastCameraHintAt != null &&
        now.difference(_lastCameraHintAt!) < const Duration(seconds: 8)) {
      return;
    }
    _lastCameraHintAt = now;
    final generation = ++_cameraHintGeneration;
    _cameraHintSpeech = _speakCameraHint(hint, generation).catchError((error) {
      debugPrint('MediScan: camera framing speech failed: $error');
    });
  }

  Future<void> _speakCameraHint(ScanHint hint, int generation) async {
    final tts = context.read<TtsProvider>();
    final voice = context.read<VoiceNavigationProvider>();
    // pauseForImageAnalysis stops the active utterance before this cue and
    // prevents voice-command listening from competing with the guidance. The
    // returned handle must always be released, including on early return.
    final pause = await voice.tryPauseForImageAnalysis();
    if (pause == null) return;
    try {
      if (!mounted || _screenDisposing || generation != _cameraHintGeneration) {
        return;
      }
      final (english, filipino) = switch (hint) {
        ScanHint.noTextFound => (
          'Move the medicine label into the center of the camera.',
          'Itapat ang etiketa ng gamot sa gitna ng camera.',
        ),
        ScanHint.moveCloser => (
          'Move the camera a little closer to the label.',
          'Ilapit nang kaunti ang camera sa etiketa.',
        ),
        ScanHint.moveFurther => (
          'Move the camera slightly farther away so the full label fits.',
          'Ilayo nang kaunti ang camera para makita ang buong etiketa.',
        ),
        ScanHint.holdSteady => (
          'Good. Hold the medicine steady while I scan the label.',
          'Mabuti. Hawakan nang hindi gumagalaw habang binabasa ko ang etiketa.',
        ),
      };
      await tts.speakCue(english, filipino);
    } finally {
      pause.release();
    }
  }

  void _onCameraOcrCapture(XFile image) {
    if (!mounted || _screenDisposing || _cameraSuspended) {
      unawaited(_deleteCaptureFile(image.path));
      return;
    }
    _streamCapturePending = true;
    final likelyPrescription = _streamDetectsPrescription;
    final previewEvidence = _previewEvidence.snapshotAndReset();
    _streamDetectsPrescription = false;
    unawaited(() async {
      try {
        await _cameraHintSpeech;
        if (!mounted || _screenDisposing || _cameraSuspended) {
          await _deleteCaptureFile(image.path);
          return;
        }
        await _captureAndReadLabel(
          automatic: true,
          capturedImage: image,
          likelyPrescription: likelyPrescription,
          previewEvidence: previewEvidence,
        );
      } finally {
        _streamCapturePending = false;
        if (mounted && !_screenDisposing && !_cameraSuspended) {
          _startAutoScan();
        }
      }
    }());
  }

  Future<void> _deleteCaptureFile(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  void _onCameraOcrError(Object error, StackTrace stack) {
    debugPrint('MediScan: camera OCR frame failed: $error');
    final stream = _cameraOcrStream;
    if (stream != null &&
        !stream.isRunning &&
        !_screenDisposing &&
        !_cameraSuspended) {
      unawaited(_startCameraOcrStreamFallback(stream));
    }
  }

  Future<void> _startCameraOcrStreamFallback(
    CameraOcrStreamService stream,
  ) async {
    try {
      await stream.stopStream();
    } catch (_) {}
    if (mounted && !_screenDisposing && !_cameraSuspended) {
      _scheduleStillAutoScans();
    }
  }

  Future<void> _toggleFlash() async {
    final controller = _cameraController;
    if (controller == null ||
        !controller.value.isInitialized ||
        _captureCycleActive ||
        _isFlashChanging ||
        _cameraSuspended) {
      return;
    }

    final nextFlashState = !_isFlashOn;
    final stream = _cameraOcrStream;
    final resumeStream = stream?.isRunning == true;
    final flashChange = Completer<void>();
    _flashChangeCompleter = flashChange;
    _autoScanTimer?.cancel();
    _initialAutoScanTimer?.cancel();
    setState(() => _isFlashChanging = true);
    try {
      // The Android camera backend rebuilds its preview session when flash
      // changes. Pause frame delivery first to avoid breaking the live stream.
      if (resumeStream) await stream!.stopStream();
      if (!mounted ||
          _screenDisposing ||
          _cameraSuspended ||
          _cameraController != controller ||
          _captureCycleActive ||
          _streamCapturePending ||
          controller.value.isTakingPicture) {
        return;
      }
      await controller.setFlashMode(
        nextFlashState ? FlashMode.torch : FlashMode.off,
      );
      if (!mounted) return;
      setState(() => _isFlashOn = nextFlashState);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Flash is not available on this camera'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (resumeStream &&
          mounted &&
          !_screenDisposing &&
          !_cameraSuspended &&
          !_captureCycleActive &&
          !_streamCapturePending &&
          !controller.value.isTakingPicture &&
          identical(_cameraController, controller) &&
          identical(_cameraOcrStream, stream)) {
        await _startCameraOcrStream(stream!);
      }
      if (mounted) setState(() => _isFlashChanging = false);
      if (identical(_flashChangeCompleter, flashChange)) {
        _flashChangeCompleter = null;
      }
      if (!flashChange.isCompleted) flashChange.complete();
      if (mounted && !_screenDisposing && !_cameraSuspended) _startAutoScan();
    }
  }

  Future<void> _toggleZoom() async {
    final controller = _cameraController;
    if (controller == null ||
        !controller.value.isInitialized ||
        _captureCycleActive ||
        _isFlashChanging ||
        _cameraSuspended) {
      return;
    }
    try {
      final maxZoom = await controller.getMaxZoomLevel();
      final target = _zoomLevel > 1.0 ? 1.0 : maxZoom.clamp(1.0, 2.0);
      if (target == _zoomLevel) return;
      await controller.setZoomLevel(target);
      if (!mounted) return;
      setState(() => _zoomLevel = target);
    } catch (_) {}
  }

  Future<void> _captureAndReadLabel({
    bool automatic = false,
    XFile? capturedImage,
    bool likelyPrescription = false,
    ScanPreviewEvidence? previewEvidence,
  }) async {
    // Preserve the latest live preview classification for a manual shutter
    // press. Single-package scans can then use the framed label crop; dense
    // prescription pages retain the full image for multi-item extraction.
    likelyPrescription = likelyPrescription || _streamDetectsPrescription;
    _streamDetectsPrescription = false;
    if (!automatic) {
      _previewEvidence.snapshotAndReset();
      _pendingStrengthConflictName = null;
    }
    if (_isFlashChanging) {
      // A capture can finish just as the torch request pauses the stream.
      // Let that image proceed after the mode change instead of discarding it.
      if (capturedImage == null) return;
      await _flashChangeCompleter?.future;
    }
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    final scanUserId = auth.userId;
    final scanUserTier = auth.tier;
    final voice = context.read<VoiceNavigationProvider>();
    final tts = context.read<TtsProvider>();
    final stream = _cameraOcrStream;
    if (!automatic && capturedImage == null && stream?.isRunning == true) {
      try {
        await stream!.stopStream();
      } catch (_) {}
    }
    if (_screenDisposing ||
        _cameraSuspended ||
        _captureCycleActive ||
        _reviewingPrescription ||
        _isGuidedFlowActive ||
        (automatic && _waitForManualScanAfterBatch)) {
      if (capturedImage != null) {
        unawaited(_deleteCaptureFile(capturedImage.path));
      }
      return;
    }
    final controller = _cameraController;
    if (controller == null ||
        !controller.value.isInitialized ||
        controller.value.isTakingPicture ||
        (capturedImage == null && controller.value.isStreamingImages) ||
        _isScanning) {
      if (capturedImage != null) {
        unawaited(_deleteCaptureFile(capturedImage.path));
      }
      return;
    }
    _captureCycleActive = true;
    if (!automatic) {
      _scanResultGate.reset();
      _waitForManualScanAfterBatch = false;
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.click);
    }

    setState(() {
      _isScanning = true;
      _scanResult = null;
      _statusMessage = automatic
          ? 'Reading automatically. Hold the medicine steady.'
          : 'Reading medicine label';
    });

    // Warm the catalog in the background. OCR can proceed immediately and
    // still has its dictionary/parser fallback if the asset is not ready.
    unawaited(PhDrugCatalog.instance.ensureLoaded());
    _imageInferenceActive = true;

    if (!automatic) {
      _speakIfVoiceNavigationEnabled(
        tts,
        'Reading label…',
        'Binabasa ang label…',
      );
    }

    String? capturedPath;
    String? preparedPath;
    String? enhancedPath;
    final captureEvidence = ScanPreviewEvidence();
    void recordPackageText(String rawText) {
      if (rawText.trim().isEmpty) return;
      final cleaned = _ocrCleanup.clean(rawText).text;
      captureEvidence.observe(_labelParser.parsePrescriptionItems(cleaned));
    }

    // Assigned only after the pause succeeds, so a throw can never release a
    // pause that was never taken.
    VoicePause? voicePause;
    void resumeVoice() {
      voicePause?.release();
      voicePause = null;
      _imageInferenceActive = false;
    }

    Future<void> cleanupCapture() async {
      final prepared = preparedPath;
      final captured = capturedPath;
      final enhanced = enhancedPath;
      preparedPath = null;
      capturedPath = null;
      enhancedPath = null;
      if (prepared != null) await _imagePreprocessor.release(prepared);
      if (enhanced != null) {
        await _imagePreprocessor.releaseGenerated(enhanced);
      }
      if (captured == null) return;
      await _imagePreprocessor.release(captured);
      try {
        await File(captured).delete();
      } catch (_) {
        // The camera may already have cleaned its temporary capture.
      }
    }

    try {
      voicePause = await voice.pauseForImageAnalysis();
      if (!mounted || _screenDisposing || _cameraSuspended) return;
      final XFile image;
      if (capturedImage != null) {
        image = capturedImage;
      } else {
        final picture = controller.takePicture();
        _pictureTask = picture;
        image = await picture;
        _pictureTask = null;
      }
      capturedPath = image.path;
      if (!mounted || _screenDisposing || _cameraSuspended) return;

      preparedPath = await _imagePreprocessor.prepareForOcr(
        image.path,
        // Stream OCR focuses on the central label ROI. Once the live read
        // recognizes a prescription page, keep the entire high-resolution
        // capture so medicine rows at the top and bottom remain available.
        centerCrop: !likelyPrescription,
      );
      if (preparedPath == null) {
        throw StateError('Image preparation unavailable');
      }
      final ocrPath = preparedPath!;
      if (mounted) setState(() => _statusMessage = 'Reading label');
      var localScan = await _ocrCoordinator.processPrescriptionImage(
        imagePath: ocrPath,
        userId: scanUserId,
        userTier: scanUserTier,
        allowCloudFallback: false,
        labelFirst: !likelyPrescription,
      );
      if (!mounted || _screenDisposing) return;
      recordPackageText(localScan.rawText);

      // Give a weak first read one local enhancement retry before considering
      // network OCR. Keep the clearer read and release the derived image when
      // all OCR consumers have finished with it.
      var localOcrPath = ocrPath;
      if (!localScan.isComplete) {
        enhancedPath = await _imagePreprocessor.getEnhancedImage(ocrPath);
        final retryPath = enhancedPath;
        if (retryPath != null) {
          final enhancedScan = await _ocrCoordinator.processPrescriptionImage(
            imagePath: retryPath,
            userId: scanUserId,
            userTier: scanUserTier,
            allowCloudFallback: false,
            labelFirst: !likelyPrescription,
          );
          recordPackageText(enhancedScan.rawText);
          if (enhancedScan.isComplete ||
              enhancedScan.medicines.length > localScan.medicines.length ||
              (enhancedScan.isCatalogVerified &&
                  !localScan.isCatalogVerified)) {
            localScan = enhancedScan;
            localOcrPath = retryPath;
          }
        }
      }
      if (!mounted || _screenDisposing) return;

      // Barcode recognition remains an offline path, but ML Kit always gets
      // the first pass. An unclear barcode is ignored and OCR stays primary.
      if (!localScan.isComplete && _barcodeScanner.canMatch) {
        if (!automatic && mounted) {
          setState(() => _statusMessage = 'Looking for a barcode');
        }
        try {
          final barcodeMatch = await _barcodeScanner.matchImage(image.path);
          if (barcodeMatch != null) {
            final entry = barcodeMatch.entry;
            final barcodeResult = MedicineLabelResult(
              name: entry.name,
              dosage: entry.dosage ?? '',
              confidence: barcodeMatch.confidence,
              nameConfidence: barcodeMatch.confidence,
              dosageConfidence: entry.dosage == null
                  ? 0
                  : barcodeMatch.confidence,
              rawText: 'Barcode match: ${entry.name}',
              source: ScanSource.barcode,
            );
            if (!mounted) return;
            if (automatic && !_scanResultGate.accept(barcodeResult)) {
              setState(() {
                _isScanning = false;
                _statusMessage =
                    'Medicine found. Hold steady for one more reading.';
              });
              return;
            }
            _autoScanTimer?.cancel();
            setState(() {
              _isScanning = false;
              _scanResult = barcodeResult;
              _statusMessage = 'Medicine found by barcode. Please confirm.';
            });
            await cleanupCapture();
            resumeVoice();
            await _checkAgainstPlanOrContinue(barcodeResult);
            return;
          }
        } catch (error) {
          debugPrint('MediScan: barcode pass unavailable: $error');
        }
      }

      // Connectivity, quota checks, and any cloud request are deferred until
      // after ML Kit and only happen when the local result is unclear.
      final coordinatedScan = localScan.isComplete
          ? localScan
          : await _ocrCoordinator.processPrescriptionImage(
              imagePath: localOcrPath,
              userId: scanUserId,
              userTier: scanUserTier,
              labelFirst: !likelyPrescription,
              localResult: localScan,
            );
      if (!mounted || _screenDisposing) return;
      recordPackageText(coordinatedScan.rawText);
      final cleanedRecognizedText = _ocrCleanup
          .clean(coordinatedScan.rawText)
          .text;
      // Preview chooses the image crop. The higher-resolution OCR text makes
      // the final package-versus-prescription decision.
      final reviewAsPrescription = _labelParser
          .detectPrescriptionDocument(cleanedRecognizedText)
          .isPrescription;
      final textKey = cleanedRecognizedText
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim()
          .toLowerCase();

      MedicineLabelResult? result;
      var prescriptionCandidates = <MedicineLabelResult>[];

      // Keep every independently recognized medicine. The previous flow only
      // kept candidates from the first OCR pass, so an enhanced pass
      // could improve the single result while silently dropping the other
      // medicines on the prescription.
      void mergePrescriptionCandidates(Iterable<MedicineLabelResult> incoming) {
        prescriptionCandidates = _labelParser.mergeReads(
          prescriptionCandidates,
          incoming,
        );
      }

      if (_labelCache.containsKey(textKey)) {
        result = _labelCache[textKey];
        if (reviewAsPrescription) {
          mergePrescriptionCandidates(
            _labelParser.parseMany(cleanedRecognizedText),
          );
        }
        debugPrint('MediScan: cached label hit');
      } else {
        result = reviewAsPrescription
            ? _labelParser.parse(cleanedRecognizedText)
            : _labelParser.parsePackage(cleanedRecognizedText);
        if (reviewAsPrescription) {
          mergePrescriptionCandidates(
            _labelParser.parseMany(cleanedRecognizedText),
          );
        }
        if (result != null) {
          if (_labelCache.length >= _maxLabelCacheSize) {
            _labelCache.remove(_labelCache.keys.first);
          }
          _labelCache[textKey] = result;
        }
      }

      if (!mounted) return;
      if (prescriptionCandidates.length == 1 &&
          (result == null || !result.nameConflict)) {
        result = prescriptionCandidates.single;
      }
      if (prescriptionCandidates.length > 1) {
        if (automatic && !_scanResultGate.acceptBatch(prescriptionCandidates)) {
          setState(() {
            _isScanning = false;
            _statusMessage =
                'Several medicines found. Hold steady while I read the prescription again.';
          });
          return;
        }
        _autoScanTimer?.cancel();
        setState(() {
          _isScanning = false;
          _statusMessage =
              'I found ${prescriptionCandidates.length} medicines. We will review each one.';
        });
        await cleanupCapture();
        resumeVoice();
        if (coordinatedScan.freeQuotaExceeded) await _speakQuotaReached();
        await _reviewMultiplePrescriptionMedicines(prescriptionCandidates);
        return;
      }
      if (result == null) {
        if (automatic) _scanResultGate.accept(null);
        setState(() {
          _isScanning = false;
          _statusMessage = coordinatedScan.freeQuotaExceeded
              ? 'Daily enhanced scan limit reached. On-device scanning is still available.'
              : 'The label is unclear. Adjust the camera and try again.';
        });
        resumeVoice();
        if (!automatic) AccessibilityFeedback.error();
        if (coordinatedScan.freeQuotaExceeded) {
          await _speakQuotaReached();
        } else {
          await _speakUnclearScan();
        }
        return;
      }

      if (!reviewAsPrescription) {
        final resultName = result.name.toLowerCase().trim();
        final observedConflict =
            captureEvidence.conflictsWith(result) ||
            (automatic && previewEvidence?.conflictsWith(result) == true);
        if (automatic && (result.strengthConflict || observedConflict)) {
          _pendingStrengthConflictName = resultName;
        }
        if ((observedConflict ||
                (automatic && _pendingStrengthConflictName == resultName)) &&
            !result.strengthConflict) {
          result = _withStrengthConflict(result);
        }
      }

      if (automatic && !_scanResultGate.accept(result)) {
        setState(() {
          _isScanning = false;
          _statusMessage = 'Medicine found. Hold steady for one more reading.';
        });
        return;
      }

      _autoScanTimer?.cancel();
      _initialAutoScanTimer?.cancel();
      setState(() {
        _isScanning = false;
        _scanResult = result;
        _statusMessage = result!.requiresDosageInput
            ? 'Medicine found. Strength needed.'
            : result.requiresNameReview
            ? 'OCR reads disagree on the name. Please check it.'
            : result.isMediumConfidence
            ? 'Possible label. Please confirm the details.'
            : 'Medicine label detected';
      });
      await cleanupCapture();
      resumeVoice();
      if (coordinatedScan.freeQuotaExceeded) await _speakQuotaReached();
      await _checkAgainstPlanOrContinue(result);
    } catch (error, stackTrace) {
      debugPrint('MediScan: label capture failed: $error\n$stackTrace');
      if (automatic) _scanResultGate.accept(null);
      if (!mounted) return;
      if (!automatic) AccessibilityFeedback.error();
      setState(() {
        _isScanning = false;
        _statusMessage = 'Scan failed. Hold steady and try again.';
      });
    } finally {
      resumeVoice();
      _imageInferenceActive = false;
      try {
        await cleanupCapture();
      } finally {
        _pictureTask = null;
        _captureCycleActive = false;
        if (_scanResult == null &&
            !_reviewingPrescription &&
            !_isGuidedFlowActive &&
            !_waitForManualScanAfterBatch) {
          _startAutoScan();
        }
      }
    }
  }

  Future<void> _reviewMultiplePrescriptionMedicines(
    List<MedicineLabelResult> candidates,
  ) async {
    _reviewingPrescription = true;
    _autoScanTimer?.cancel();
    try {
      for (var index = 0; index < candidates.length; index++) {
        final candidate = candidates[index];
        if (!mounted) return;
        setState(() {
          _scanResult = candidate;
          _statusMessage =
              'Reviewing medicine ${index + 1} of ${candidates.length}: ${candidate.name}';
        });
        final answered = await _confirmDetectedMedicine(candidate);
        if (!answered) break;
        if (!mounted) return;
      }
    } finally {
      _reviewingPrescription = false;
      if (mounted) _resetScanFlow(afterBatch: true);
    }
  }

  /// A package scan is a verification step when a reviewed medication plan
  /// already contains the medicine.  Only an exact name-and-strength match is
  /// allowed to say "matches"; this code does not make a clinical decision or
  /// tell the person to take a medicine.
  Future<void> _checkAgainstPlanOrContinue(MedicineLabelResult result) async {
    final tts = context.read<TtsProvider>();
    // OCR confidence is a safety input, not just UI decoration. A weak read
    // must never silently validate a medicine, but the elder gets a simple,
    // accessible confirmation question instead of a technical error.
    if (result.confidence < 0.75 || result.nameConfidence < 0.75) {
      AccessibilityFeedback.error();
      if (mounted) {
        setState(() => _statusMessage = 'Please confirm what I found.');
      }
      // A readable candidate needs confirmation, not a prompt to reposition
      // the camera. The confirmation sheet speaks the finding once.
      await _confirmDetectedMedicine(result);
      return;
    }
    final medications = context.read<MedicationProvider>().medications;
    if (medications.isEmpty) {
      if (mounted) {
        setState(() {
          _unrecognizedAlert = true;
          _statusMessage = 'This medicine is not in your saved medicine list.';
        });
      }
      final addAsNew = await _askToReviewNewPrescription(
        result,
        hasActivePlan: false,
      );
      if (addAsNew == true && mounted) {
        await _confirmDetectedMedicine(result);
      } else if (mounted) {
        _resetScanFlow(
          message: 'Review dismissed. Point the camera at another medicine.',
        );
      }
      return;
    }

    final check = PrescriptionSafety.check(
      scannedName: result.name,
      scannedStrength: result.dosage,
      activeMedications: medications,
    );
    final medication = check.medication;
    switch (check.verdict) {
      case PrescriptionScanVerdict.matchesPlan:
        final name = MedicineSpeechFormatter.medicineName(medication!.name);
        final strength = MedicineSpeechFormatter.strength(medication.dosage);
        await _speakIfVoiceNavigationEnabled(
          tts,
          '$name, $strength, matches your reviewed medication plan. Check your schedule before taking it.',
          '$name, $strength, ay tugma sa planong gamot na iyong nasuri. Tingnan ang iyong iskedyul bago ito inumin.',
        );
        if (mounted) {
          setState(() {
            _unrecognizedAlert = false;
            _statusMessage = 'Matches your reviewed plan. Check schedule.';
          });
        }
        // A plan match is still a scan result that needs an explicit user
        // confirmation. Previously this branch stopped after the status/TTS
        // update, leaving the user with no "Oo / Confirm" action.
        await _confirmDetectedMedicine(result);
        return;
      case PrescriptionScanVerdict.strengthMismatch:
        AccessibilityFeedback.error();
        final name = _spokenMedicineName(result);
        await _speakIfVoiceNavigationEnabled(
          tts,
          'Safety check. $name was found, but the strength does not match your reviewed plan. Do not confirm this medicine. Ask your guardian or pharmacist.',
          'Pagsusuri sa kaligtasan. May nakita akong $name, ngunit hindi tugma ang lakas nito sa planong gamot na iyong nasuri. Huwag itong kumpirmahin. Magtanong sa iyong tagapag-alaga o parmasyutiko.',
        );
        if (mounted) {
          setState(() {
            _unrecognizedAlert = false;
            _statusMessage = 'Strength does not match the reviewed plan.';
          });
        }
        return;
      case PrescriptionScanVerdict.notInPlan:
        if (mounted) setState(() => _unrecognizedAlert = true);
        final addAsNew = await _askToReviewNewPrescription(result);
        if (addAsNew == true && mounted) {
          await _confirmDetectedMedicine(result);
        } else if (mounted) {
          _resetScanFlow(
            message: 'Review dismissed. Point the camera at another medicine.',
          );
        }
        return;
      case PrescriptionScanVerdict.unclear:
        // OCR omitted a field needed for comparison. The existing explicit
        // confirmation flow is the safe fallback; it never activates a plan
        // without the user's review.
        await _confirmDetectedMedicine(result);
    }
  }

  Future<bool?> _askToReviewNewPrescription(
    MedicineLabelResult result, {
    bool hasActivePlan = true,
  }) async {
    final tts = context.read<TtsProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final amber = isDark ? Colors.amber.shade300 : Colors.amber.shade700;
    final englishWarning = hasActivePlan
        ? '${result.name} is not in your saved medication list. Do not take it until it has been reviewed. Would you like to review it as a new prescription?'
        : 'You do not have a saved medication list yet. ${result.name} is not saved. Do not take it until it has been reviewed. Would you like to review it as a new prescription?';
    final filipinoWarning = hasActivePlan
        ? 'Wala ang ${result.name} sa iyong naka-save na listahan ng gamot. Huwag itong inumin hangga\'t hindi pa nasusuri. Gusto mo ba itong suriin bilang bagong reseta?'
        : 'Wala ka pang naka-save na listahan ng gamot. Hindi naka-save ang ${result.name}. Huwag itong inumin hangga\'t hindi pa nasusuri. Gusto mo ba itong suriin bilang bagong reseta?';
    // Finish the warning before presenting the dialog so elderly or blind
    // users never hear the prompt clipped by the next interaction.
    await _speakIfVoiceNavigationEnabled(tts, englishWarning, filipinoWarning);
    if (!mounted) return null;
    return showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) => Dialog(
        backgroundColor: isDark ? AppTheme.darkCardSurface : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: amber.withValues(alpha: 0.16),
                  ),
                  child: Icon(
                    Icons.warning_amber_rounded,
                    color: amber,
                    size: 36,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                hasActivePlan
                    ? 'Not in your saved medicine list'
                    : 'No saved medicine list yet',
                textAlign: TextAlign.center,
                style: AppTheme.textStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: isDark
                      ? AppTheme.darkTextPrimary
                      : AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: amber.withValues(alpha: 0.5)),
                ),
                child: Text(
                  'Detected: ${result.name}${_safeStrengthLabel(result)}',
                  textAlign: TextAlign.center,
                  style: AppTheme.textStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: isDark
                        ? AppTheme.darkTextPrimary
                        : AppTheme.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                hasActivePlan
                    ? '${result.name} is not in your active saved medicine list. Do not take it until a guardian, pharmacist, or patient reviews the prescription details.'
                    : '${result.name} is not saved in your current medicine list. Do not take it until a guardian, pharmacist, or patient reviews the prescription details.',
                textAlign: TextAlign.center,
                style: AppTheme.textStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: isDark
                      ? AppTheme.darkTextSecondary
                      : AppTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  backgroundColor: amber,
                  foregroundColor: Colors.black,
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Review Prescription'),
              ),
              const SizedBox(height: 8),
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  foregroundColor: isDark
                      ? AppTheme.darkTextSecondary
                      : AppTheme.mutedText,
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Dismiss  ·  Scan Again'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The strength inside the "Detected:" chip. An implausible gram read
  /// (likely a lost "m" in "mg") is suppressed so it never renders as
  /// something like "1000 g" and is only ever entered by the user.
  String _safeStrengthLabel(MedicineLabelResult result) {
    if (result.strengthNeedsReview || result.dosage.isEmpty) return '';
    return ' (${result.dosage})';
  }

  MedicineLabelResult _withStrengthConflict(MedicineLabelResult result) =>
      MedicineLabelResult(
        name: result.name,
        dosage: '',
        confidence: result.confidence.clamp(0.0, 0.74),
        nameConfidence: result.nameConfidence,
        dosageConfidence: 0,
        rawText: result.rawText,
        kind: result.kind,
        source: result.source,
        barcode: result.barcode,
        strengthConflict: true,
        nameConflict: result.nameConflict,
        alternativeName: result.alternativeName,
      );

  String _spokenMedicineName(MedicineLabelResult result) =>
      MedicineSpeechFormatter.medicineName(result.name);

  String _spokenMedicineStrength(MedicineLabelResult result) =>
      MedicineSpeechFormatter.strength(result.dosage);

  MedicineExpiryInfo? _expiryInfo(MedicineLabelResult result) =>
      MedicineExpiryParser.parse(result.rawText);

  Future<void> _showExpiredMedicineWarning(
    MedicineExpiryInfo expiry,
    TtsProvider tts,
  ) async {
    final date = MedicineExpiryParser.format(expiry);
    await tts.speak(
      'This medicine is expired. The expiration date is $date. Do not take or add it.',
      'Expired na ang medicine na to. Ang expiration date ay $date. Huwag itong inumin o idagdag.',
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.red),
        title: const Text('Medicine has expired'),
        content: Text(
          'The label says this medicine expired in $date. Do not take or add it. Please scan another medicine or ask a pharmacist.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('I understand'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDetectedMedicine(MedicineLabelResult result) async {
    if (_isGuidedFlowActive) return false;
    _isGuidedFlowActive = true;

    // Keep the preview alive while guided voice confirmation runs. The
    // controller is created with enableAudio:false, so it does not claim the
    // microphone; disposing it here causes camera restart stalls and dropped
    // STT frames on Android.
    _autoScanTimer?.cancel();

    final tts = context.read<TtsProvider>();
    final voice = context.read<VoiceNavigationProvider>();
    // A failed pause must not block the guided flow, so fall back to no pause
    // rather than aborting the review.
    VoicePause? pause;
    try {
      pause = await voice.pauseNavigation();
    } catch (error) {
      debugPrint('MediScan: navigation microphone pause failed: $error');
    }
    try {
      await _stopGuidedAudio(tts, voice);
      if (!mounted) return false;
      final expiry = _expiryInfo(result);
      if (expiry?.isExpired == true) {
        await _showExpiredMedicineWarning(expiry!, tts);
        return false;
      }
      final confirmed = await _askMedicineConfirmation(
        result,
        tts,
        voice,
        expiry,
      );
      await _stopGuidedAudio(tts, voice);
      if (!mounted) return false;
      if (confirmed == _MedicineDecision.yes) {
        final dosageOverride = await _askDoseIfUncertain(result, tts, voice);
        if (!mounted) return false;
        if (result.doseNeedsChoice && dosageOverride == null) {
          _resetGuidedState(keepResult: _reviewingPrescription);
          return false;
        }
        return await _startGuidedSchedule(
          result,
          dosageOverride: dosageOverride,
        );
      } else if (confirmed == _MedicineDecision.edit) {
        return await _startGuidedSchedule(
          MedicineLabelResult(
            name: result.name,
            dosage: '',
            confidence: result.confidence,
            nameConfidence: result.nameConfidence,
            dosageConfidence: 0,
            rawText: result.rawText,
            kind: result.kind,
            source: result.source,
          ),
        );
      } else if (confirmed == _MedicineDecision.no) {
        await _speakIfVoiceNavigationEnabled(
          tts,
          _reviewingPrescription
              ? 'Okay, skipping this medicine. Let us review the next one.'
              : 'Okay, please point the camera at the correct medicine label.',
          _reviewingPrescription
              ? 'Sige, lalaktawan ang gamot na ito. Suriin natin ang kasunod.'
              : 'Sige, itapat ang camera sa tamang label ng gamot.',
        );
        if (_reviewingPrescription) {
          _resetGuidedState(keepResult: true);
        } else {
          _resetScanFlow(
            message: 'Scan rejected. Point the camera at another medicine.',
          );
        }
        return true;
      } else {
        _resetScanFlow(
          message: 'Scan dismissed. Point the camera at another medicine.',
        );
        return false;
      }
    } finally {
      pause?.release();
      if (mounted && _isGuidedFlowActive) {
        _resetGuidedState(keepResult: _reviewingPrescription);
      }
    }
  }

  /// When the label's strength expression makes the real per-dose amount
  /// ambiguous ("100 mg / 5 mL"), ask which part is the dose with large
  /// choices. Returns the chosen dose string, or null to keep the original.
  Future<String?> _askDoseIfUncertain(
    MedicineLabelResult result,
    TtsProvider tts,
    VoiceNavigationProvider voice,
  ) async {
    if (!result.doseNeedsChoice) return null;

    final parsed = Dosage.parse(result.dosage);
    if (parsed == null || parsed.secondValue == null) return null;
    final alt1 = '${Dosage.formatNumber(parsed.value!)} ${parsed.unit}';
    final alt2 =
        '${Dosage.formatNumber(parsed.secondValue!)} ${parsed.secondUnit}';

    final useVoice = await _prepareGuidedVoice(voice);
    if (!mounted) return null;
    final micGate = _GuidedMicGate(voice);
    final decision = Completer<String?>();
    final sheetResult = showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _DoseChoiceSheet(
        alt1: alt1,
        alt2: alt2,
        showVoiceControl: useVoice,
        onVoiceTap: micGate.tap,
      ),
    );
    sheetResult.then((chosen) {
      if (!decision.isCompleted) {
        tts.stop();
        decision.complete(chosen);
      }
    });

    if (useVoice) {
      unawaited(() async {
        try {
          await tts.speak(
            'I am not sure about the dose. Is it $alt1 or $alt2? Say first or second, or say the amount.',
            'Hindi ako sigurado sa dosis. $alt1 ba o $alt2? Sabihin ang una o pangalawa, o banggitin ang dami.',
          );
          await _waitForTts(tts);
        } catch (error) {
          debugPrint('MediScan: dose question speech unavailable: $error');
          return;
        }
        if (!mounted || decision.isCompleted) return;

        var failedAttempts = 0;
        while (mounted && !decision.isCompleted) {
          String? spokenAnswer;
          try {
            spokenAnswer = await voice.listenForScanAnswer(
              duration: const Duration(seconds: 8),
            );
          } catch (error) {
            debugPrint('MediScan: dose answer unavailable: $error');
            return;
          }
          if (!mounted || decision.isCompleted) return;
          if (!voice.pushToTalkMode) return;

          final choice = _doseChoiceFromSpeech(spokenAnswer, alt1, alt2);
          if (choice != null) {
            await tts.speak(
              'Okay, using $choice.',
              'Sige, $choice ang gagamitin.',
            );
            if (!mounted || decision.isCompleted) return;
            HapticFeedback.lightImpact();
            Navigator.of(context).pop(choice);
            decision.complete(choice);
            return;
          }

          failedAttempts++;
          await tts.speak(
            failedAttempts == 1
                ? 'I did not catch that. Say first or second, or choose the dose on the screen.'
                : 'Tap the microphone to try again, or choose the dose on the screen.',
            failedAttempts == 1
                ? 'Hindi ko naintindihan. Sabihin ang una o pangalawa, o piliin ang dosis sa screen.'
                : 'Pindutin ang mikropono para sumubok muli, o piliin ang dosis sa screen.',
          );
          await _waitForTts(tts);
          if (!mounted || decision.isCompleted) return;

          if (failedAttempts > 1 &&
              !await micGate.waitForTapOr(decision.future)) {
            return;
          }
        }
      }());
    }

    final choice = await decision.future;
    if (useVoice) await _stopGuidedAudio(tts, voice);
    return choice;
  }

  /// Resolve only an explicit ordinal or a clear amount/unit match. If the
  /// speech is ambiguous, leave the large on-screen choices available rather
  /// than guessing which part of a strength expression is the dose.
  String? _doseChoiceFromSpeech(String? text, String alt1, String alt2) {
    if (text == null || text.trim().isEmpty) return null;
    final normalized = text
        .toLowerCase()
        .replaceAll('[unk]', ' ')
        .replaceAll(RegExp(r'[^a-z0-9.]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (RegExp(r'\b(first|1st|una|unang)\b').hasMatch(normalized)) {
      return alt1;
    }
    if (RegExp(r'\b(second|2nd|pangalawa|ikalawa)\b').hasMatch(normalized)) {
      return alt2;
    }

    final first = Dosage.parse(alt1);
    final second = Dosage.parse(alt2);
    if (first == null || second == null) return null;
    final units = <String, String>{
      'mg': 'mg',
      'milligram': 'mg',
      'milligrams': 'mg',
      'miligramos': 'mg',
      'mcg': 'mcg',
      'g': 'g',
      'gram': 'g',
      'grams': 'g',
      'ml': 'ml',
      'milliliter': 'ml',
      'milliliters': 'ml',
      'millilitre': 'ml',
      'millilitres': 'ml',
      'mililitro': 'ml',
      'mililitros': 'ml',
      'unit': 'units',
      'units': 'units',
      'tablet': 'tablet',
      'tablets': 'tablet',
      'capsule': 'capsule',
      'capsules': 'capsule',
      'drops': 'drops',
      'puffs': 'puffs',
    };
    final spokenUnits = normalized
        .split(' ')
        .map((word) => units[word])
        .whereType<String>()
        .toSet();
    final firstUnit = units[(first.unit ?? '').toLowerCase()];
    final secondUnit = units[(second.unit ?? '').toLowerCase()];
    if (spokenUnits.length == 1) {
      final spokenUnit = spokenUnits.single;
      if (firstUnit == spokenUnit && secondUnit != spokenUnit) return alt1;
      if (secondUnit == spokenUnit && firstUnit != spokenUnit) return alt2;
    }

    final spokenNumbers = RegExp(r'\b\d+(?:\.\d+)?\b')
        .allMatches(normalized)
        .map((match) => double.tryParse(match.group(0)!))
        .whereType<double>()
        .toSet();
    final firstValue = first.value;
    final secondValue = second.value;
    final matchesFirst =
        firstValue != null && spokenNumbers.contains(firstValue);
    final matchesSecond =
        secondValue != null && spokenNumbers.contains(secondValue);
    if (matchesFirst != matchesSecond) return matchesFirst ? alt1 : alt2;
    return null;
  }

  Future<bool> _startGuidedSchedule(
    MedicineLabelResult result, {
    String? dosageOverride,
  }) async {
    // Typed SIG instructions are useful only when they map to one of our
    // fixed, reviewable schedule options. Handwriting/unknown wording falls
    // through to the existing large-button/voice question.
    final parsedInstruction = const PrescriptionInstructionParser().parse(
      result.rawText,
    );

    // If strength was not visible, show the form immediately. The form has a
    // clearly visible dosage field and can still carry any safely parsed SIG
    // frequency/quantity; asking more voice questions first made this field
    // easy to miss or appear to disappear.
    if (result.requiresDosageInput && dosageOverride == null) {
      final saved = await _openMedicationEntry(
        result: result,
        frequency: parsedInstruction.frequency,
        quantityDispensed: parsedInstruction.quantityDispensed,
        unitsPerDose: parsedInstruction.unitsPerDose,
        requireDosage: true,
      );
      _resetGuidedState(keepResult: _reviewingPrescription);
      return saved;
    }

    final frequency =
        parsedInstruction.frequency ?? await _askFrequency(result);
    if (!mounted) return false;
    if (frequency == null) {
      _resetGuidedState();
      return false;
    }

    final time = await _askTime(result);
    if (!mounted) return false;
    if (time == null) {
      _resetGuidedState();
      return false;
    }

    final saved = await _openMedicationEntry(
      result: result,
      frequency: frequency,
      time: time,
      dosageOverride: dosageOverride,
      quantityDispensed: parsedInstruction.quantityDispensed,
      unitsPerDose: parsedInstruction.unitsPerDose,
    );
    _resetGuidedState(keepResult: _reviewingPrescription);
    return saved;
  }

  Future<String?> _askFrequency(MedicineLabelResult result) async {
    final tts = context.read<TtsProvider>();
    final voice = context.read<VoiceNavigationProvider>();
    final useVoice = await _prepareGuidedVoice(voice);
    if (!mounted) return null;
    final micGate = _GuidedMicGate(voice);
    final decision = Completer<String?>();
    final sheetResult = showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _GuidedFrequencySheet(
        medicineName: result.name,
        frequencies: _guidedFrequencies,
        showVoiceControl: useVoice,
        onVoiceTap: micGate.tap,
      ),
    );
    sheetResult.then((frequency) {
      if (!decision.isCompleted) {
        decision.complete(frequency);
      }
    });

    Future<void>? spokenPrompt;
    if (useVoice) {
      spokenPrompt = tts.speak(
        'How many times will you take this in one day?',
        'Ilang beses mo ito iinumin bawat araw?',
      );
    }

    if (useVoice) {
      unawaited(() async {
        try {
          await spokenPrompt!;
          await _waitForTts(tts);
        } catch (error) {
          debugPrint('MediScan: frequency speech unavailable: $error');
          return;
        }
        if (!mounted || decision.isCompleted) return;

        var failedAttempts = 0;
        while (mounted && !decision.isCompleted) {
          String? spokenAnswer;
          try {
            spokenAnswer = await voice.listenForScanAnswer(
              duration: const Duration(seconds: 8),
            );
          } catch (error) {
            debugPrint('MediScan: frequency answer unavailable: $error');
            return;
          }
          if (!mounted || decision.isCompleted) return;
          if (!voice.pushToTalkMode) return;

          final frequency = _frequencyFromSpeech(spokenAnswer);
          if (frequency != null) {
            await tts.speak(
              'Got it. $frequency.',
              'Sige. ${_frequencyInFilipino(frequency)}.',
            );
            if (!mounted || decision.isCompleted) return;
            HapticFeedback.lightImpact();
            Navigator.of(context).pop(frequency);
            decision.complete(frequency);
            return;
          }

          failedAttempts++;
          await tts.speak(
            failedAttempts == 1
                ? 'I did not catch how many times. Say once, twice, three times, or every four hours.'
                : 'Tap the microphone to try again, or choose a frequency on the screen.',
            failedAttempts == 1
                ? 'Hindi ko naintindihan kung ilang beses. Sabihin ang isang beses, dalawang beses, tatlong beses, o tuwing apat na oras.'
                : 'Pindutin ang mikropono para sumubok muli, o pumili ng dalas sa screen.',
          );
          await _waitForTts(tts);
          if (!mounted || decision.isCompleted) return;

          if (failedAttempts > 1 &&
              !await micGate.waitForTapOr(decision.future)) {
            return;
          }
        }
      }());
    }

    final choice = await decision.future;
    if (useVoice) await _stopGuidedAudio(tts, voice);
    return choice;
  }

  Future<TimeOfDay?> _askTime(MedicineLabelResult result) async {
    final tts = context.read<TtsProvider>();
    final voice = context.read<VoiceNavigationProvider>();
    final useVoice = await _prepareGuidedVoice(voice);
    if (!mounted) return null;
    final micGate = _GuidedMicGate(voice);

    final decision = Completer<TimeOfDay?>();

    // Show a guided bottom sheet immediately (like frequency flow) so the
    // UI is ready while TTS speaks. The sheet will be popped with the
    // selected time when available.
    final sheetResult = showModalBottomSheet<TimeOfDay?>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _GuidedTimeSheet(
        medicineName: result.name,
        showVoiceControl: useVoice,
        onVoiceTap: micGate.tap,
      ),
    );

    sheetResult.then((picked) {
      if (!decision.isCompleted) {
        decision.complete(picked);
      }
    });

    Future<void>? spokenPrompt;
    if (useVoice) {
      spokenPrompt = tts.speak(
        'What time will you take it?',
        'Anong oras mo ito iinumin?',
      );
    }

    if (useVoice) {
      unawaited(() async {
        try {
          await spokenPrompt!;
          await _waitForTts(tts);
        } catch (error) {
          debugPrint('MediScan: time speech unavailable: $error');
          return;
        }
        if (!mounted || decision.isCompleted) return;

        var failedAttempts = 0;
        while (mounted && !decision.isCompleted) {
          String? spokenAnswer;
          try {
            spokenAnswer = await voice.listenForScanAnswer(
              duration: const Duration(seconds: 8),
            );
          } catch (error) {
            debugPrint('MediScan: time answer unavailable: $error');
            return;
          }
          if (!mounted || decision.isCompleted) return;
          if (!voice.pushToTalkMode) return;

          final time = _timeFromSpeech(spokenAnswer);
          if (time != null) {
            await tts.speak(
              'Got it. ${time.format(context)}.',
              'Sige. ${time.format(context)}.',
            );
            if (!mounted || decision.isCompleted) return;
            HapticFeedback.lightImpact();
            if (Navigator.of(context).canPop()) Navigator.of(context).pop(time);
            decision.complete(time);
            return;
          }

          failedAttempts++;
          await tts.speak(
            failedAttempts == 1
                ? 'I did not catch a time. Say a time such as 7 AM or 10 PM, or say now.'
                : 'Tap the microphone to try again, or pick a time on the screen.',
            failedAttempts == 1
                ? 'Hindi ko naintindihan ang oras. Sabihin ang alas otso ng umaga, alas diyes ng gabi, o ngayon.'
                : 'Pindutin ang mikropono para sumubok muli, o pumili ng oras sa screen.',
          );
          await _waitForTts(tts);
          if (!mounted || decision.isCompleted) return;

          if (failedAttempts > 1 &&
              !await micGate.waitForTapOr(decision.future)) {
            return;
          }
        }
      }());
    }

    final choice = await decision.future;
    if (useVoice) await _stopGuidedAudio(tts, voice);
    return choice;
  }

  Future<void> _stopGuidedAudio(
    TtsProvider tts,
    VoiceNavigationProvider voice,
  ) async {
    try {
      await tts.stop();
    } catch (error) {
      debugPrint('MediScan: speech cleanup failed: $error');
    }
    try {
      await voice.stopScanAnswer();
    } catch (error) {
      debugPrint('MediScan: voice answer cleanup failed: $error');
    }
  }

  Future<void> _waitForTts(TtsProvider tts) async {
    if (!tts.isSpeaking) {
      await Future.delayed(const Duration(milliseconds: 250));
      return;
    }

    final completer = Completer<void>();
    void listener() {
      if (!tts.isSpeaking && !completer.isCompleted) {
        completer.complete();
      }
    }

    tts.addListener(listener);
    try {
      if (!tts.isSpeaking && !completer.isCompleted) {
        completer.complete();
      }
      await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {},
      );
    } finally {
      tts.removeListener(listener);
    }
    await Future.delayed(const Duration(milliseconds: 250));
  }

  /// Scanner speech follows the same opt-in as command capture.
  Future<void> _speakIfVoiceNavigationEnabled(
    TtsProvider tts,
    String english,
    String filipino,
  ) {
    if (!context.read<AppStateProvider>().voiceNavigationEnabled) {
      return Future<void>.value();
    }
    if (_imageInferenceActive) return Future<void>.value();
    final now = DateTime.now();
    if (_lastVoiceFeedback == english &&
        _lastVoiceFeedbackAt != null &&
        now.difference(_lastVoiceFeedbackAt!) < const Duration(seconds: 3)) {
      return Future<void>.value();
    }
    _lastVoiceFeedback = english;
    _lastVoiceFeedbackAt = now;
    final next = _voiceFeedbackQueue.then((_) async {
      if (!_imageInferenceActive && mounted) {
        await tts.speak(english, filipino);
        await _waitForTts(tts);
      }
    });
    _voiceFeedbackQueue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _speakUnclearScan() {
    final now = DateTime.now();
    if (_lastUnclearPromptAt != null &&
        now.difference(_lastUnclearPromptAt!) < const Duration(seconds: 12)) {
      return Future<void>.value();
    }
    _lastUnclearPromptAt = now;
    return _speakIfVoiceNavigationEnabled(
      context.read<TtsProvider>(),
      'I had trouble reading the label clearly. Please adjust the lighting, hold steady, or speak the medicine name.',
      'Nahihirapan akong basahin ang etiketa. Ayusin ang ilaw, hawakan nang hindi gumagalaw, o sabihin ang pangalan ng gamot.',
    );
  }

  Future<void> _speakQuotaReached() {
    final now = DateTime.now();
    final previous = _lastQuotaPromptAt;
    if (previous != null &&
        previous.year == now.year &&
        previous.month == now.month &&
        previous.day == now.day) {
      return Future<void>.value();
    }
    _lastQuotaPromptAt = now;
    return _speakIfVoiceNavigationEnabled(
      context.read<TtsProvider>(),
      'Daily enhanced scan limit reached. You can still scan on-device or upgrade to MediSense Pro.',
      'Naabot na ang pang-araw-araw na limitasyon ng pinahusay na pag-scan. Maaari ka pa ring mag-scan sa device o mag-upgrade sa MediSense Pro.',
    );
  }

  /// Manual scan controls remain available when Voice Navigation is off or
  /// the optional offline model cannot be prepared.
  Future<bool> _prepareGuidedVoice(VoiceNavigationProvider voice) async {
    if (!context.read<AppStateProvider>().voiceNavigationEnabled) return false;
    if (voice.isVoskInitialized) return true;
    try {
      final ready = await showModelDownloadSheet(context);
      return mounted &&
          ready &&
          context.read<AppStateProvider>().voiceNavigationEnabled;
    } catch (error) {
      debugPrint('MediScan: guided voice unavailable: $error');
      return false;
    }
  }

  Future<_MedicineDecision?> _askMedicineConfirmation(
    MedicineLabelResult result,
    TtsProvider tts,
    VoiceNavigationProvider voice,
    MedicineExpiryInfo? expiry,
  ) async {
    final useVoice = await _prepareGuidedVoice(voice);
    if (!mounted) return null;
    final micGate = _GuidedMicGate(voice);
    final decision = Completer<_MedicineDecision?>();
    final sheetResult = showModalBottomSheet<_MedicineDecision>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      // Do not let a stray tap outside the sheet or a drag gesture silently
      // discard the scan result. The sheet has explicit actions for confirm,
      // reject, edit, and close.
      isDismissible: false,
      enableDrag: false,
      builder: (context) => SingleChildScrollView(
        child: _MedicineConfirmationSheet(
          result: result,
          expiry: expiry,
          showVoiceControl: useVoice,
          onVoiceTap: micGate.tap,
        ),
      ),
    );
    sheetResult.then((confirmed) {
      if (!decision.isCompleted) {
        decision.complete(confirmed);
      }
    });

    final spokenName = _spokenMedicineName(result);
    final spokenStrength = _spokenMedicineStrength(result);
    final parsedFrequency = const PrescriptionInstructionParser()
        .parse(result.rawText)
        .frequency;
    final spokenFrequency = switch (parsedFrequency) {
      'Once a day' => 'Once daily',
      'Twice a day' => 'Twice daily',
      'Three times a day' => 'Three times daily',
      final value? => value,
      null => '',
    };
    final findingDetails = [
      if (spokenStrength.isNotEmpty) spokenStrength,
      if (spokenFrequency.isNotEmpty) spokenFrequency,
    ].join(', ');
    final englishPrompt = result.nameConflict
        ? 'The scans disagree on the medicine name: ${result.name} or ${result.alternativeName}. Check the prescription before confirming.'
        : result.strengthConflict
        ? 'The scans disagree on the strength of $spokenName. Please check the label and enter the strength yourself after confirming the medicine.'
        : result.strengthNeedsReview
        ? 'The strength reading for $spokenName looks unusual. Please check the label and enter the strength yourself after confirming the medicine.'
        : result.requiresDosageInput
        ? 'I found $spokenName, but I cannot see the strength. Please enter the amount in milligrams or grams after you confirm this medicine.'
        : result.isHighConfidence
        ? 'I found $spokenName${findingDetails.isEmpty ? '' : ', $findingDetails'}. Would you like to add this to your schedule?'
        : 'I found a possible label. Please confirm the details. Is $spokenName $spokenStrength the medicine you will take?';
    final filipinoPrompt = result.nameConflict
        ? 'Magkaiba ang nabasang pangalan ng gamot: ${result.name} o ${result.alternativeName}. Suriin ang reseta bago kumpirmahin.'
        : result.strengthConflict
        ? 'Magkaiba ang nabasang lakas ng $spokenName. Pakisuri ang etiketa at ilagay ang tamang lakas pagkatapos kumpirmahin ang gamot.'
        : result.strengthNeedsReview
        ? 'Mukhang kakaiba ang nabasang lakas ng $spokenName. Pakisuri ang etiketa at ilagay ang tamang lakas pagkatapos kumpirmahin ang gamot.'
        : result.requiresDosageInput
        ? 'Nakita ko ang $spokenName, ngunit hindi ko makita ang lakas nito. Ilagay ang dami sa milligram o gram pagkatapos mong kumpirmahin ang gamot.'
        : result.isHighConfidence
        ? 'Nakita ko ang $spokenName${findingDetails.isEmpty ? '' : ', $findingDetails'}. Gusto mo ba itong idagdag sa iskedyul mo?'
        : 'Nakahanap ako ng posibleng etiketa. Pakikumpirma ang mga detalye. Ito ba ang gamot na iinumin mo: $spokenName $spokenStrength?';
    final expiryEnglish = expiry == null
        ? ''
        : ' The expiration date on the label is ${MedicineExpiryParser.format(expiry)}.';
    final expiryFilipino = expiry == null
        ? ''
        : ' Ang petsa ng pagkapaso sa etiketa ay ${MedicineExpiryParser.format(expiry)}.';
    Future<void>? spokenPrompt;
    if (useVoice) {
      spokenPrompt = tts.speak(
        '$englishPrompt$expiryEnglish',
        '$filipinoPrompt$expiryFilipino',
      );
    }

    if (useVoice) {
      unawaited(() async {
        try {
          await spokenPrompt!;
          await _waitForTts(tts);
        } catch (error) {
          debugPrint('MediScan: confirmation speech unavailable: $error');
          return;
        }
        if (!mounted || decision.isCompleted) return;

        var failedAttempts = 0;
        while (mounted && !decision.isCompleted) {
          String? spokenResult;
          try {
            spokenResult = await voice.listenForScanAnswer(
              duration: const Duration(seconds: 8),
            );
          } catch (error) {
            debugPrint('MediScan: voice answer unavailable: $error');
            return;
          }
          if (!mounted || decision.isCompleted) return;
          if (!voice.pushToTalkMode) return;

          if (_isYes(spokenResult) || _isNo(spokenResult)) {
            final isYes = _isYes(spokenResult);
            final confirmed = isYes
                ? _MedicineDecision.yes
                : _MedicineDecision.no;
            await tts.speak(
              isYes
                  ? 'Okay, I will add this medicine.'
                  : 'Okay, I will skip this medicine.',
              isYes
                  ? 'Sige, idaragdag ko ang gamot na ito.'
                  : 'Sige, lalaktawan ko ang gamot na ito.',
            );
            if (!mounted || decision.isCompleted) return;
            HapticFeedback.lightImpact();
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop(confirmed);
            }
            decision.complete(confirmed);
            return;
          }

          failedAttempts++;
          await tts.speak(
            failedAttempts == 1
                ? 'Please answer yes or no. Say yes, oo, no, or hindi.'
                : 'Tap the microphone to answer again, or choose a button.',
            failedAttempts == 1
                ? 'Pakisagot ng oo o hindi.'
                : 'Pindutin ang mikropono para sumagot muli, o pumili ng button.',
          );
          await _waitForTts(tts);
          if (!mounted || decision.isCompleted) return;

          if (failedAttempts > 1 &&
              !await micGate.waitForTapOr(decision.future)) {
            return;
          }
        }
      }());
    }

    return decision.future;
  }

  bool _isYes(String? text) {
    return ScanSpeechParser.isYes(text);
  }

  bool _isNo(String? text) {
    return ScanSpeechParser.isNo(text);
  }

  String? _frequencyFromSpeech(String? text) {
    return ScanSpeechParser.frequencyFromSpeech(text);
  }

  String _frequencyInFilipino(String frequency) {
    switch (frequency) {
      case 'Once a day':
        return 'Isang beses sa isang araw';
      case 'Twice a day':
        return 'Dalawang beses sa isang araw';
      case 'Three times a day':
        return 'Tatlong beses sa isang araw';
      case 'Every 4 hours':
        return 'Tuwing apat na oras';
      case 'Every 6 hours':
        return 'Tuwing anim na oras';
      case 'Every 8 hours':
        return 'Tuwing walong oras';
      case 'Every 12 hours':
        return 'Tuwing labindalawang oras';
      case 'As needed':
        return 'Kapag kailangan';
      default:
        return frequency;
    }
  }

  TimeOfDay? _timeFromSpeech(String? text) {
    return ScanSpeechParser.timeFromSpeech(text);
  }

  void _resetScanFlow({bool afterBatch = false, String? message}) {
    if (!mounted) return;
    _scanResultGate.reset();
    _pendingStrengthConflictName = null;
    _waitForManualScanAfterBatch = afterBatch;
    setState(() {
      _scanResult = null;
      _unrecognizedAlert = false;
      _statusMessage =
          message ??
          (afterBatch
              ? 'Review complete. Tap Scan to read another prescription.'
              : 'Auto-reading medicine label');
      _isGuidedFlowActive = false;
    });
    if (!afterBatch) _startAutoScan();
  }

  void _resetGuidedState({bool keepResult = false}) {
    if (!mounted) return;
    if (!keepResult) _scanResultGate.reset();
    setState(() {
      _isGuidedFlowActive = false;
      if (!keepResult) {
        _scanResult = null;
      }
    });
    // Re-acquire the camera after the guided voice flow ends so the user
    // can scan again.  The timer is started inside _initializeCamera only
    // when _isGuidedFlowActive is false.
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      _initializeCamera();
    } else if (!_reviewingPrescription) {
      _startAutoScan();
    }
  }

  Future<bool> _openMedicationEntry({
    MedicineLabelResult? result,
    String? frequency,
    TimeOfDay? time,
    String? dosageOverride,
    int? quantityDispensed,
    double? unitsPerDose,
    bool requireDosage = false,
  }) async {
    var saved = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: true,
      enableDrag: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AddMedicationModal(
        initialName: result?.name,
        initialDosage: requireDosage ? null : dosageOverride ?? result?.dosage,
        initialExpirationDate: result == null
            ? null
            : _expiryInfo(result)?.effectiveExpirationDate,
        initialFrequency: frequency,
        initialTime: time,
        initialQuantityDispensed: quantityDispensed,
        initialUnitsPerDose: unitsPerDose,
        onSaved: () => saved = true,
      ),
    );
    return saved;
  }

  @override
  Widget build(BuildContext context) {
    final cameraReady =
        _cameraController != null && _cameraController!.value.isInitialized;
    final mode = context.watch<AppStateProvider>().accessibilityMode;
    final isElder = mode.isElder || mode.isVisionLoss;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        centerTitle: true,
        title: Text(
          'MediSense',
          style: AppTheme.textStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 22,
          ),
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: SizedBox.expand(
              key: _previewAreaKey,
              child: cameraReady
                  ? CameraPreview(_cameraController!)
                  : _CameraFallback(
                      isLoading: _isInitializing,
                      message: _statusMessage ?? 'Camera is unavailable',
                    ),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.55),
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.72),
                  ],
                ),
              ),
            ),
          ),
          // The reading state gets its own lane above the viewfinder.
          // Keeping it out of the camera controls prevents long OCR
          // messages from colliding with the action labels.
          Positioned(
            left: 16,
            right: 16,
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 12,
            child: _ScanInstructionBanner(
              alert: _unrecognizedAlert,
              icon: _unrecognizedAlert
                  ? Icons.warning_amber_rounded
                  : _scanResult == null
                  ? Icons.document_scanner_rounded
                  : Icons.check_circle_rounded,
              text: _unrecognizedAlert
                  ? 'Unrecognized Medication'
                  : _statusMessage ?? 'Align medicine label within frame',
            ),
          ),
          Center(
            child: SizedBox(
              key: _reticleKey,
              width: 280,
              height: 280,
              child: Stack(
                children: [
                  CustomPaint(
                    painter: _ViewfinderPainter(
                      color: _unrecognizedAlert
                          ? const Color(0xFFF59E0B)
                          : _scanResult == null
                          ? AppTheme.accentGreen
                          : AppTheme.success,
                    ),
                    size: Size.infinite,
                  ),
                  if (_isScanning) _ScanningLine(),
                ],
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            // Scaffold already removes bottomNavigationBar from the body's
            // layout height. Anchor directly to that edge so the controls
            // cannot drift upward when the large-text nav is used. The nav
            // bar is hidden on the viewfinder, so keep clear of the system
            // gesture area too.
            bottom: 0,
            child: SafeArea(
              top: false,
              child: _ScanControls(
                isFlashOn: _isFlashOn,
                zoom: _zoomLevel,
                onTorch:
                    cameraReady && !_isFlashChanging && !_captureCycleActive
                    ? _toggleFlash
                    : null,
                onZoomToggle: cameraReady ? _toggleZoom : null,
                onCapture: cameraReady
                    ? () => _captureAndReadLabel(automatic: false)
                    : null,
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: isElder
          ? ElderBottomNav(
              currentRoute: '/scan',
              dark: true,
              visionLoss: mode.isVisionLoss,
            )
          : const MediBottomNav(currentRoute: '/scan', dark: true),
    );
  }
}

/// Native-style camera controls: a large centered shutter with only the two
/// secondary actions needed around it. Keeping this row small prevents the
/// primary action from drifting to the edge on narrow phones.
class _ScanControls extends StatelessWidget {
  final bool isFlashOn;
  final double zoom;
  final VoidCallback? onTorch;
  final VoidCallback? onZoomToggle;
  final VoidCallback? onCapture;

  const _ScanControls({
    required this.isFlashOn,
    required this.zoom,
    required this.onTorch,
    required this.onZoomToggle,
    required this.onCapture,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 84),
      child: SizedBox(
        width: double.infinity,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _CameraSideAction(
              icon: isFlashOn
                  ? Icons.flash_on_rounded
                  : Icons.flash_off_rounded,
              label: 'Torch',
              onTap: onTorch,
              selected: isFlashOn,
            ),
            _CameraShutter(onTap: onCapture),
            _CameraSideAction(
              icon: Icons.zoom_in_rounded,
              label: 'Zoom',
              circleText: '${zoom.round()}×',
              onTap: onZoomToggle,
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraSideAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? circleText;
  final VoidCallback? onTap;
  final bool selected;

  const _CameraSideAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.circleText,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          customBorder: const CircleBorder(),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: enabled ? 1 : 0.35,
            child: SizedBox(
              width: 72,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: selected
                          ? Colors.white.withValues(alpha: 0.92)
                          : const Color(0xFF2A2A2A).withValues(alpha: 0.92),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.9),
                        width: 1.5,
                      ),
                    ),
                    child: Center(
                      child: circleText == null
                          ? Icon(icon, color: Colors.white, size: 25)
                          : Text(
                              circleText!,
                              maxLines: 1,
                              style: AppTheme.textStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: AppTheme.textStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CameraShutter extends StatelessWidget {
  final VoidCallback? onTap;

  const _CameraShutter({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Capture medicine label',
      child: Material(
        color: Colors.transparent,
        child: InkResponse(
          onTap: onTap,
          containedInkWell: true,
          customBorder: const CircleBorder(),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: enabled ? 1 : 0.42,
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.transparent,
                border: Border.all(color: Colors.white, width: 4),
              ),
              padding: const EdgeInsets.all(8),
              child: Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFFE2A374),
                ),
                child: const Icon(
                  Icons.camera_alt_rounded,
                  color: Colors.white,
                  size: 30,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MedicineConfirmationSheet extends StatelessWidget {
  final MedicineLabelResult result;
  final MedicineExpiryInfo? expiry;
  final bool showVoiceControl;
  final VoidCallback? onVoiceTap;

  const _MedicineConfirmationSheet({
    required this.result,
    this.expiry,
    this.showVoiceControl = false,
    this.onVoiceTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkSurface : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: List.generate(
                5,
                (index) => Expanded(
                  child: Container(
                    height: 4,
                    margin: EdgeInsets.only(right: index == 4 ? 0 : 5),
                    decoration: BoxDecoration(
                      color: index == 0 ? AppTheme.ink : AppTheme.timber,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Check the medicine',
              style: AppTheme.textStyle(
                color: isDark ? AppTheme.darkTextPrimary : AppTheme.inkText,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              result.nameConflict
                  ? 'Magkaiba ang nabasang pangalan: ${result.name} o ${result.alternativeName}. Suriin ang reseta bago kumpirmahin.'
                  : result.strengthConflict
                  ? '${result.name} ba ang gamot? Magkaiba ang nabasang lakas; ilagay ito nang manu-mano.'
                  : result.strengthNeedsReview
                  ? '${result.name} ba ang gamot? Mukhang mali ang nabasang ${result.dosage}; ilagay ang tamang lakas.'
                  : '${result.name} ${result.dosage} ba ang iinumin mo?',
              style: AppTheme.textStyle(
                color: isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.textSecondary,
                fontSize: 15,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 18),
            if (expiry != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.foil.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Expiration date on label: ${MedicineExpiryParser.format(expiry!)}',
                  style: AppTheme.textStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: isDark
                        ? AppTheme.darkTextPrimary
                        : AppTheme.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark ? AppTheme.darkCardSurface : AppTheme.paper,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isDark ? AppTheme.darkBorder : AppTheme.timber,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: AppTheme.foil.withValues(alpha: .16),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.medication_rounded,
                      color: AppTheme.foil,
                      size: 29,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          result.name,
                          style: AppTheme.textStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: isDark
                                ? AppTheme.darkTextPrimary
                                : AppTheme.inkText,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          result.dosage.isEmpty
                              ? 'Dosage needs review'
                              : result.dosage,
                          style: AppTheme.textStyle(
                            fontSize: 14,
                            color: isDark
                                ? AppTheme.darkTextSecondary
                                : AppTheme.mutedText,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.ink.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      '${(result.confidence * 100).round()}% match',
                      style: AppTheme.textStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (showVoiceControl) ...[
              const SizedBox(height: 14),
              _ScanAnswerMicControl(onPressed: onVoiceTap),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () =>
                    Navigator.of(context).pop(_MedicineDecision.yes),
                icon: const Icon(Icons.check_rounded),
                label: const Text('Oo / Confirm'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.ink,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(56),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () =>
                    Navigator.of(context).pop(_MedicineDecision.no),
                icon: const Icon(Icons.close_rounded),
                label: const Text('Hindi / Wrong Medicine'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  foregroundColor: isDark
                      ? AppTheme.darkTextPrimary
                      : AppTheme.inkText,
                  side: BorderSide(
                    color: isDark ? AppTheme.darkBorder : AppTheme.timber,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
            Center(
              child: TextButton.icon(
                onPressed: () =>
                    Navigator.of(context).pop(_MedicineDecision.edit),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Edit medicine details'),
              ),
            ),
            Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close and scan later'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Keeps a usable microphone control visible above the modal barrier while
/// MediScan is waiting for a guided voice answer.
class _ScanAnswerMicControl extends StatelessWidget {
  final VoidCallback? onPressed;

  const _ScanAnswerMicControl({this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Consumer<VoiceNavigationProvider>(
      builder: (context, voice, _) {
        final listening = voice.isScanAnswerListening;
        final enabled = voice.pushToTalkMode && onPressed != null;
        return Semantics(
          button: true,
          enabled: enabled,
          label: !voice.pushToTalkMode
              ? 'Voice navigation is off. Choose an option on the screen.'
              : listening
              ? 'Microphone is listening. Tap to keep listening longer.'
              : 'Tap the microphone to answer or listen again.',
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: !enabled
                  ? null
                  : () {
                      if (!voice.extendScanAnswerListening()) onPressed!();
                      HapticFeedback.selectionClick();
                    },
              icon: Icon(
                listening ? Icons.mic_rounded : Icons.mic_none_rounded,
              ),
              label: Text(
                !voice.pushToTalkMode
                    ? 'Voice navigation is off'
                    : listening
                    ? 'Nakikinig ako • Tap para makinig pa'
                    : 'Pindutin ang mic para sumagot muli',
                textAlign: TextAlign.center,
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                foregroundColor: Theme.of(context).colorScheme.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Large-choice sheet for an ambiguous strength dose ("100 mg / 5 mL"):
/// "Is it 5 mL or 100 mg?" with both alternatives plus "Other".
class _DoseChoiceSheet extends StatelessWidget {
  final String alt1;
  final String alt2;
  final bool showVoiceControl;
  final VoidCallback? onVoiceTap;

  const _DoseChoiceSheet({
    required this.alt1,
    required this.alt2,
    this.showVoiceControl = false,
    this.onVoiceTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? AppTheme.darkSurface : Colors.white;
    final ink = isDark ? AppTheme.darkTextPrimary : AppTheme.textPrimary;
    final muted = isDark ? AppTheme.darkTextSecondary : AppTheme.textSecondary;

    return FractionallySizedBox(
      heightFactor: 0.88,
      alignment: Alignment.bottomCenter,
      child: Container(
        decoration: BoxDecoration(
          color: surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 28),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'I\'m not sure about the dose.',
                  style: AppTheme.textStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: ink,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Is it $alt1 or $alt2?',
                  style: AppTheme.textStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Choose the dose you actually take.',
                  style: AppTheme.textStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: muted,
                  ),
                ),
                if (showVoiceControl) ...[
                  const SizedBox(height: 12),
                  _ScanAnswerMicControl(onPressed: onVoiceTap),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  height: 68,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(alt1),
                    icon: const Icon(Icons.check_rounded, size: 28),
                    label: Text(
                      alt1,
                      style: AppTheme.textStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primaryDark,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 68,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(alt2),
                    icon: const Icon(Icons.check_rounded, size: 28),
                    label: Text(
                      alt2,
                      style: AppTheme.textStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primaryDark,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 60,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: ink,
                      side: BorderSide(
                        color: ink.withValues(alpha: 0.35),
                        width: 2,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    child: Text(
                      'Other',
                      style: AppTheme.textStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: ink,
                      ),
                    ),
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

class _GuidedFrequencySheet extends StatelessWidget {
  final String medicineName;
  final List<String> frequencies;
  final bool showVoiceControl;
  final VoidCallback? onVoiceTap;

  const _GuidedFrequencySheet({
    required this.medicineName,
    required this.frequencies,
    this.showVoiceControl = false,
    this.onVoiceTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = AppTheme.primaryTextColor(context);
    final muted = AppTheme.secondaryTextColor(context);
    final action = Theme.of(context).colorScheme.primary;
    return FractionallySizedBox(
      heightFactor: 0.72,
      alignment: Alignment.bottomCenter,
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkSurface : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        child: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                medicineName,
                softWrap: true,
                style: AppTheme.textStyle(
                  color: muted,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Ilang beses mo ito iinumin sa isang araw?',
                style: AppTheme.textStyle(
                  color: ink,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (showVoiceControl) ...[
                const SizedBox(height: 10),
                _ScanAnswerMicControl(onPressed: onVoiceTap),
              ],
              const SizedBox(height: 18),
              Expanded(
                child: ListView.builder(
                  itemCount: frequencies.length,
                  itemBuilder: (context, index) {
                    final frequency = frequencies[index];
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom: index == frequencies.length - 1 ? 0 : 10,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(frequency),
                          style: OutlinedButton.styleFrom(
                            alignment: Alignment.centerLeft,
                            foregroundColor: action,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 16,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: Text(
                            frequency,
                            style: AppTheme.textStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GuidedTimeSheet extends StatefulWidget {
  final String medicineName;
  final bool showVoiceControl;
  final VoidCallback? onVoiceTap;

  const _GuidedTimeSheet({
    required this.medicineName,
    this.showVoiceControl = false,
    this.onVoiceTap,
  });

  @override
  State<_GuidedTimeSheet> createState() => _GuidedTimeSheetState();
}

class _GuidedTimeSheetState extends State<_GuidedTimeSheet> {
  bool _isPickerShowing = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = AppTheme.primaryTextColor(context);
    final muted = AppTheme.secondaryTextColor(context);
    final action = Theme.of(context).colorScheme.primary;
    return FractionallySizedBox(
      heightFactor: 0.44,
      alignment: Alignment.bottomCenter,
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkSurface : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.medicineName,
                softWrap: true,
                style: AppTheme.textStyle(
                  color: muted,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Anong oras mo ito iinumin?',
                style: AppTheme.textStyle(
                  color: ink,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 18),
              Center(
                child: Text(
                  'Say a time such as 7 AM or 10 PM, or say “ngayon” — or pick a time',
                  textAlign: TextAlign.center,
                  style: AppTheme.textStyle(
                    color: muted,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (widget.showVoiceControl) ...[
                const SizedBox(height: 10),
                _ScanAnswerMicControl(onPressed: widget.onVoiceTap),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _isPickerShowing
                      ? null
                      : () async {
                          setState(() => _isPickerShowing = true);
                          final nav = Navigator.of(context);
                          final picked = await showTimePicker(
                            context: nav.context,
                            initialTime: const TimeOfDay(hour: 8, minute: 0),
                            useRootNavigator: true,
                          );
                          if (mounted) setState(() => _isPickerShowing = false);

                          if (picked != null && nav.canPop()) {
                            nav.pop(picked);
                          }
                        },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: action,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    'Pick a time',
                    style: AppTheme.textStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
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

class _ScanInstructionBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool alert;

  const _ScanInstructionBanner({
    required this.icon,
    required this.text,
    this.alert = false,
  });

  @override
  Widget build(BuildContext context) {
    final amber = Colors.amber.shade400;
    return Semantics(
      liveRegion: true,
      label: text,
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48, maxWidth: 360),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: alert
                ? Colors.amber.shade800.withValues(alpha: 0.94)
                : Colors.black.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: alert ? amber : Colors.white.withValues(alpha: 0.72),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: AppTheme.ink.withValues(alpha: 0.22),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: alert ? amber : AppTheme.foil, size: 22),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  text,
                  style: AppTheme.textStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
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

class _CameraFallback extends StatelessWidget {
  final bool isLoading;
  final String message;

  const _CameraFallback({required this.isLoading, required this.message});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLoading)
              const CircularProgressIndicator(color: Colors.white)
            else
              Icon(
                Icons.no_photography_rounded,
                size: 88,
                color: Colors.white.withValues(alpha: 0.24),
              ),
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: AppTheme.textStyle(
                  color: Colors.white.withValues(alpha: 0.78),
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanningLine extends StatefulWidget {
  @override
  State<_ScanningLine> createState() => _ScanningLineState();
}

class _ScanningLineState extends State<_ScanningLine>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Positioned(
          top: 280 * _controller.value,
          left: 20,
          right: 20,
          child: Container(
            height: 2,
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: AppTheme.accentGreen.withValues(alpha: 0.5),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ],
              gradient: LinearGradient(
                colors: [
                  AppTheme.accentGreen.withValues(alpha: 0),
                  AppTheme.accentGreen,
                  AppTheme.accentGreen.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ViewfinderPainter extends CustomPainter {
  final Color color;
  _ViewfinderPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const double cornerSize = 40;
    const double radius = 24;

    canvas.drawPath(
      Path()
        ..moveTo(0, cornerSize)
        ..lineTo(0, radius)
        ..quadraticBezierTo(0, 0, radius, 0)
        ..lineTo(cornerSize, 0),
      paint,
    );

    canvas.drawPath(
      Path()
        ..moveTo(size.width - cornerSize, 0)
        ..lineTo(size.width - radius, 0)
        ..quadraticBezierTo(size.width, 0, size.width, radius)
        ..lineTo(size.width, cornerSize),
      paint,
    );

    canvas.drawPath(
      Path()
        ..moveTo(size.width, size.height - cornerSize)
        ..lineTo(size.width, size.height - radius)
        ..quadraticBezierTo(
          size.width,
          size.height,
          size.width - radius,
          size.height,
        )
        ..lineTo(size.width - cornerSize, size.height),
      paint,
    );

    canvas.drawPath(
      Path()
        ..moveTo(cornerSize, size.height)
        ..lineTo(radius, size.height)
        ..quadraticBezierTo(0, size.height, 0, size.height - radius)
        ..lineTo(0, size.height - cornerSize),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _ViewfinderPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
