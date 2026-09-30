import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'ocr_capture_stability_gate.dart';

enum ScanHint { noTextFound, moveCloser, moveFurther, holdSteady }

/// Uses a supplied recognizer or owns one, but never owns [camera].
/// Initialize the camera with NV21 on Android or BGRA8888 on iOS; the scan
/// screen uses a 720p camera profile.
/// YUV420 Android streams are also supported, including padded pixel strides.
/// Preview OCR never touches disk. Only the final takePicture creates a file;
/// ownership of that file passes to [onCapture]. Capture pauses the stream:
/// call startStream again to scan another label. Await dispose before disposing
/// the camera. Close a supplied recognizer after this service is disposed.
/// Lifecycle methods must not be awaited from synchronous callbacks.
class CameraOcrStreamService {
  CameraOcrStreamService({
    required this.camera,
    required this.onHint,
    required this.onCapture,
    required this.onError,
    this.onText,
    this.previewMedicineName,
    TextRecognizer? textRecognizer,
    this.maxDimension = 1280,
    this.minSharpness = 100,
    this.minTextCoverageForGuidance = .03,
    this.frameInterval = const Duration(milliseconds: 150),
    this.hintInterval = const Duration(seconds: 3),
  }) : _recognizer =
           textRecognizer ??
           TextRecognizer(script: TextRecognitionScript.latin),
       _ownsRecognizer = textRecognizer == null {
    if (maxDimension < 64 ||
        minSharpness < 0 ||
        minTextCoverageForGuidance < 0 ||
        minTextCoverageForGuidance > 1 ||
        frameInterval.isNegative ||
        hintInterval.isNegative) {
      throw ArgumentError('Invalid OCR stream configuration');
    }
  }

  final CameraController camera;
  final ValueChanged<ScanHint> onHint;
  final ValueChanged<XFile> onCapture;
  final void Function(Object error, StackTrace stack) onError;
  final ValueChanged<RecognizedText>? onText;

  /// Resolves an unambiguous medicine prefix for capture readiness only.
  final String? Function(String text)? previewMedicineName;
  final int maxDimension;

  /// Variance of the luminance Laplacian; calibrate on target devices.
  final double minSharpness;

  /// Text boxes are much smaller than the physical label, so this is only a
  /// framing hint threshold; it must never block an otherwise stable capture.
  final double minTextCoverageForGuidance;
  final Duration frameInterval;
  final Duration hintInterval;
  final TextRecognizer _recognizer;
  final bool _ownsRecognizer;
  late final OcrCaptureStabilityGate _captureGate = OcrCaptureStabilityGate(
    minSharpness: minSharpness,
    minTextCoverage: minTextCoverageForGuidance,
  );
  final Stopwatch _clock = Stopwatch()..start();
  Future<void> _lifecycle = Future<void>.value();
  Future<void>? _frame;
  Future<void>? _disposal;
  CameraImage? _latestImage;
  Timer? _frameTimer;
  Isolate? _frameWorker;
  ReceivePort? _frameResponses;
  SendPort? _frameRequests;
  Future<void>? _startingFrameWorker;
  Completer<PreparedOcrFrame>? _pendingPreparation;
  bool _frameWorkerExited = false;
  bool _running = false;
  bool _disposed = false;
  int _generation = 0;
  Duration _lastFrame = Duration.zero;
  Duration _lastText = Duration.zero;
  Duration? _lastHint;

  bool get isRunning => _running;

  Future<void> _serialize(Future<void> Function() action) {
    final next = _lifecycle.then((_) => action());
    _lifecycle = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> startStream() => _serialize(() async {
    if (_disposed) throw StateError('OCR service is disposed');
    if (_running) return;
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw UnsupportedError('ML Kit requires Android or iOS');
    }
    await _frame;
    if (!camera.value.isInitialized || camera.value.isStreamingImages) {
      throw StateError('An initialized, idle camera is required');
    }
    _lastText = _clock.elapsed;
    _lastHint = null;
    _captureGate.reset();
    _clearLatestImage();
    _lastFrame = _clock.elapsed - frameInterval;
    _running = true;
    final generation = ++_generation;
    try {
      await camera.startImageStream((image) {
        if (!_current(generation)) return;
        // Keep only the newest frame while OCR is busy, as in ML Kit's live
        // camera sample. Old frames must never form a backlog.
        _latestImage = image;
        _processLatest(generation);
      });
    } catch (_) {
      _running = false;
      _clearLatestImage();
      rethrow;
    }
  });

  Future<void> stopStream() {
    _running = false;
    ++_generation;
    _clearLatestImage();
    return _serialize(() async {
      // A queued start may have run since stop was requested.
      _running = false;
      ++_generation;
      _clearLatestImage();
      await _frame;
      if (camera.value.isStreamingImages) await camera.stopImageStream();
    });
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    try {
      await stopStream();
    } finally {
      _pendingPreparation?.completeError(
        StateError('OCR frame worker disposed'),
      );
      _pendingPreparation = null;
      _frameWorker?.kill(priority: Isolate.immediate);
      _frameResponses?.close();
      if (_ownsRecognizer) await _recognizer.close();
      _clock.stop();
    }
  }

  Future<PreparedOcrFrame> _prepareFrame(OcrFrameRequest request) async {
    await (_startingFrameWorker ??= _startFrameWorker());
    if (_disposed || _frameRequests == null) {
      throw StateError('OCR frame worker unavailable');
    }
    final pending = Completer<PreparedOcrFrame>();
    _pendingPreparation = pending;
    _frameRequests!.send(request);
    try {
      return await pending.future;
    } finally {
      if (identical(_pendingPreparation, pending)) _pendingPreparation = null;
    }
  }

  Future<void> _startFrameWorker() async {
    final responses = ReceivePort();
    final ready = Completer<SendPort>();
    _frameResponses = responses;
    _frameWorkerExited = false;
    responses.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
      } else if (message is List &&
          message.length == 5 &&
          message[0] is TransferableTypedData) {
        final pending = _pendingPreparation;
        if (pending != null && !pending.isCompleted) {
          pending.complete(
            PreparedOcrFrame(
              (message[0] as TransferableTypedData).materialize().asUint8List(),
              message[1] as int,
              message[2] as int,
              message[3] as bool,
              message[4] as double,
            ),
          );
        }
      } else if (message is String) {
        final pending = _pendingPreparation;
        if (pending != null && !pending.isCompleted) {
          pending.completeError(StateError(message));
        }
      } else if (message == null) {
        _frameWorkerExited = true;
        final error = StateError('OCR frame worker stopped');
        if (!ready.isCompleted) ready.completeError(error);
        final pending = _pendingPreparation;
        if (pending != null && !pending.isCompleted) {
          pending.completeError(error);
        }
        _frameRequests = null;
      }
    });
    try {
      _frameWorker = await Isolate.spawn(
        _ocrFrameWorker,
        responses.sendPort,
        errorsAreFatal: true,
        onExit: responses.sendPort,
      );
      _frameRequests = await ready.future;
      if (_frameWorkerExited) {
        throw StateError('OCR frame worker stopped during startup');
      }
    } catch (_) {
      _frameRequests = null;
      _frameWorker?.kill(priority: Isolate.immediate);
      _frameWorker = null;
      responses.close();
      _frameResponses = null;
      _startingFrameWorker = null;
      rethrow;
    }
  }

  bool _current(int generation) =>
      !_disposed && _running && generation == _generation;

  void _clearLatestImage() {
    _latestImage = null;
    _frameTimer?.cancel();
    _frameTimer = null;
  }

  void _processLatest(int generation) {
    if (!_current(generation) || _frame != null || _latestImage == null) return;
    final wait = frameInterval - (_clock.elapsed - _lastFrame);
    if (wait > Duration.zero) {
      _frameTimer ??= Timer(wait, () {
        _frameTimer = null;
        _processLatest(generation);
      });
      return;
    }
    _frameTimer?.cancel();
    _frameTimer = null;
    final image = _latestImage!;
    _latestImage = null;
    _lastFrame = _clock.elapsed;
    _frame = _process(image, generation).whenComplete(() {
      _frame = null;
      _processLatest(generation);
    });
  }

  void _hint(ScanHint hint) {
    if (_lastHint != null && _clock.elapsed - _lastHint! < hintInterval) {
      return;
    }
    _lastHint = _clock.elapsed;
    onHint(hint);
  }

  Future<void> _process(CameraImage image, int generation) async {
    try {
      final rotation = _rotation();
      // Packing and resize run on a persistent worker. Only one frame is in
      // flight; new camera frames are dropped rather than queued behind OCR.
      final directNv21 =
          Platform.isAndroid &&
          image.format.group == ImageFormatGroup.nv21 &&
          image.planes.length == 1 &&
          image.planes.first.bytesPerRow == image.width &&
          image.width <= maxDimension &&
          image.height <= maxDimension &&
          image.planes.first.bytes.length >=
              image.width * image.height * 3 ~/ 2;
      final frame = directNv21
          ? PreparedOcrFrame(
              image.planes.first.bytes,
              image.width,
              image.height,
              false,
              0,
            )
          : await _prepareFrame(
              OcrFrameRequest(
                width: image.width,
                height: image.height,
                format: image.format.group,
                planes: image.planes
                    .map(
                      (p) => OcrPlane(
                        p.bytes,
                        p.bytesPerRow,
                        p.bytesPerPixel ?? 1,
                      ),
                    )
                    .toList(),
                maxDimension: maxDimension,
                rotation: Platform.isIOS ? rotation.rawValue : 0,
              ),
            );
      if (!_current(generation)) return;
      final text = await _recognizer.processImage(
        InputImage.fromBytes(
          bytes: frame.bytes,
          metadata: InputImageMetadata(
            size: Size(frame.width.toDouble(), frame.height.toDouble()),
            rotation: Platform.isIOS
                ? InputImageRotation.rotation0deg
                : rotation,
            format: frame.bgra
                ? InputImageFormat.bgra8888
                : InputImageFormat.nv21,
            bytesPerRow: directNv21
                ? image.planes.first.bytesPerRow
                : frame.width * (frame.bgra ? 4 : 1),
          ),
        ),
      );
      if (!_current(generation)) return;
      onText?.call(text);
      if (!_current(generation)) return;
      final rotated =
          Platform.isAndroid &&
          (rotation == InputImageRotation.rotation90deg ||
              rotation == InputImageRotation.rotation270deg);
      final size = Size(
        (rotated ? frame.height : frame.width).toDouble(),
        (rotated ? frame.width : frame.height).toDouble(),
      );
      final roi = Offset.zero & size;
      final boxes = text.blocks
          .where((b) => b.text.trim().isNotEmpty)
          .map((b) => b.boundingBox)
          .toList();
      if (boxes.isEmpty) {
        _captureGate.miss(_clock.elapsed);
        if (_clock.elapsed - _lastText >= const Duration(seconds: 3)) {
          _hint(ScanHint.noTextFound);
        }
        return;
      }
      _lastText = _clock.elapsed;
      final edgeMargin = math.min(size.width, size.height) * .005;
      final significantBoxes = boxes
          .where((b) => b.width * b.height >= roi.width * roi.height * .001)
          .toList();
      final clippedAtEdge = significantBoxes.any(
        (b) =>
            b.left < edgeMargin ||
            b.top < edgeMargin ||
            b.right > size.width - edgeMargin ||
            b.bottom > size.height - edgeMargin,
      );
      final coverage = ocrBoxCoverage(boxes, roi);
      // Keep continuous focus and exposure while a hand-held label moves.
      // Calculate sharpness on Android's direct path only when ML Kit has read
      // medicine-like text, rather than on every preview frame.
      var captureReady = false;
      final medicineName = previewMedicineName?.call(text.text);
      if (_hasMedicineSignal(text.text, medicineName)) {
        captureReady = _captureGate.observe(
          text: text.text,
          medicineName: medicineName,
          at: _clock.elapsed,
          coverage: coverage,
          clippedAtEdge: clippedAtEdge,
          sharpness: directNv21
              ? estimateLumaSharpness(frame.bytes, frame.width, frame.height)
              : frame.sharpness,
        );
      } else {
        _captureGate.miss(_clock.elapsed);
      }
      if (!captureReady) {
        if (_captureGate.shouldPromptHoldSteady) {
          _hint(ScanHint.holdSteady);
        } else if (clippedAtEdge) {
          _hint(ScanHint.moveFurther);
        } else if (coverage < minTextCoverageForGuidance) {
          _hint(ScanHint.moveCloser);
        }
        return;
      }
      if (!_current(generation)) return;
      await camera.stopImageStream();
      if (!_current(generation)) return;
      final capture = await camera.takePicture();
      if (!_current(generation)) {
        await File(capture.path).delete();
        return;
      }
      _running = false;
      _clearLatestImage();
      onCapture(capture);
    } catch (error, stack) {
      if (!_disposed && generation == _generation) {
        _captureGate.reset();
        // A failing frame format or worker would otherwise fail on every
        // camera callback. Let the screen switch to still-image scanning.
        _running = false;
        _clearLatestImage();
        debugPrint('Camera OCR frame failed: $error');
        // Reporting errors must not create an unhandled asynchronous Future.
        try {
          onError(error, stack);
        } catch (_) {
          /* consumer error */
        }
      }
    }
  }

  InputImageRotation _rotation() {
    const orientations = {
      DeviceOrientation.portraitUp: 0,
      DeviceOrientation.landscapeLeft: 90,
      DeviceOrientation.portraitDown: 180,
      DeviceOrientation.landscapeRight: 270,
    };
    final device = orientations[camera.value.deviceOrientation]!;
    final sensor = camera.description.sensorOrientation;
    final degrees =
        camera.description.lensDirection == CameraLensDirection.front
        ? (sensor + device) % 360
        : (sensor - device + 360) % 360;
    return InputImageRotationValue.fromRawValue(degrees)!;
  }

  bool _hasMedicineSignal(String text, String? medicineName) {
    final strength = RegExp(
      r'\b\d+(?:[.,]\d+)?\s*(?:mg|mcg|\u03bcg|\u00b5g|ug|g|ml|iu|units?)\b',
      caseSensitive: false,
    ).hasMatch(text);
    if (strength) return true;

    if (medicineName != null) return true;

    // Some package faces show the medicine name in the camera ROI while the
    // strength is on a side panel. Let stable label text reach the capture
    // gate; full-resolution OCR and the parser still validate the image.
    final words = RegExp(r'[a-z]{4,}', caseSensitive: false).allMatches(text);
    return text.trim().length >= 10 && words.length >= 2;
  }
}

@visibleForTesting
class OcrPlane {
  const OcrPlane(this.bytes, this.rowStride, this.pixelStride);
  final Uint8List bytes;
  final int rowStride;
  final int pixelStride;
}

@visibleForTesting
class OcrFrameRequest {
  const OcrFrameRequest({
    required this.width,
    required this.height,
    required this.format,
    required this.planes,
    required this.maxDimension,
    this.rotation = 0,
  });
  final int width, height, maxDimension;
  final int rotation;
  final ImageFormatGroup format;
  final List<OcrPlane> planes;
}

@visibleForTesting
class PreparedOcrFrame {
  const PreparedOcrFrame(
    this.bytes,
    this.width,
    this.height,
    this.bgra,
    this.sharpness,
  );
  final Uint8List bytes;
  final int width, height;
  final bool bgra;
  final double sharpness;
}

/// Estimate focus from a tightly packed luminance plane. The Android fast
/// path calls this only for stable, sparse reads.
@visibleForTesting
double estimateLumaSharpness(Uint8List bytes, int width, int height) {
  if (width < 3 || height < 3 || bytes.length < width * height) return 0;
  double sum = 0, squares = 0;
  var count = 0;
  for (var y = 1; y < height - 1; y += 2) {
    for (var x = 1; x < width - 1; x += 2) {
      final i = y * width + x;
      final value =
          bytes[i - 1] +
          bytes[i + 1] +
          bytes[i - width] +
          bytes[i + width] -
          4 * bytes[i];
      sum += value;
      squares += value * value;
      count++;
    }
  }
  return math.max(0, squares / count - math.pow(sum / count, 2)).toDouble();
}

void _ocrFrameWorker(SendPort host) {
  final requests = ReceivePort();
  host.send(requests.sendPort);
  requests.listen((message) {
    try {
      final frame = prepareOcrFrame(message as OcrFrameRequest);
      host.send([
        TransferableTypedData.fromList([frame.bytes]),
        frame.width,
        frame.height,
        frame.bgra,
        frame.sharpness,
      ]);
    } catch (error) {
      host.send(error.toString());
    }
  });
}

/// Broad central target (96% width, 92% height) retains names and directions
/// near package edges while reducing input size. Even chroma alignment is
/// required for NV21/YUV420; nearest-neighbour sampling avoids RGB conversion.
@visibleForTesting
PreparedOcrFrame prepareOcrFrame(OcrFrameRequest source) {
  final bgra = source.format == ImageFormatGroup.bgra8888;
  final nv21 = source.format == ImageFormatGroup.nv21;
  if (!bgra && !nv21 && source.format != ImageFormatGroup.yuv420) {
    throw UnsupportedError('Use NV21, YUV420 or BGRA8888 camera frames');
  }
  if (source.width < 4 ||
      source.height < 4 ||
      source.maxDimension < 2 ||
      source.planes.length != (bgra || nv21 ? 1 : 3)) {
    throw ArgumentError('Invalid camera frame');
  }
  int even(int value) => value ~/ 2 * 2;
  final cw = math.max(2, even((source.width * .96).floor()));
  final ch = math.max(2, even((source.height * .92).floor()));
  final left = even((source.width - cw) ~/ 2);
  final top = even((source.height - ch) ~/ 2);
  final scale = math.min(1.0, source.maxDimension / math.max(cw, ch));
  final w = math.max(2, even((cw * scale).floor()));
  final h = math.max(2, even((ch * scale).floor()));
  final bytes = Uint8List(bgra ? w * h * 4 : w * h * 3 ~/ 2);
  final luma = bgra ? Uint8List(w * h) : bytes;
  final first = source.planes.first;
  for (var y = 0; y < h; y++) {
    final sy = top + y * ch ~/ h;
    for (var x = 0; x < w; x++) {
      final sx = left + x * cw ~/ w;
      final src = sy * first.rowStride + sx * (bgra ? 4 : first.pixelStride);
      final dst = y * w + x;
      if (bgra) {
        bytes.setRange(dst * 4, dst * 4 + 4, first.bytes, src);
        luma[dst] =
            (29 * first.bytes[src] +
                150 * first.bytes[src + 1] +
                77 * first.bytes[src + 2]) >>
            8;
      } else {
        bytes[dst] = first.bytes[src];
      }
    }
  }
  if (!bgra) {
    for (var y = 0; y < h ~/ 2; y++) {
      final sy = top ~/ 2 + y * ch ~/ h;
      for (var x = 0; x < w ~/ 2; x++) {
        final sx = left ~/ 2 + x * cw ~/ w;
        final dst = w * h + y * w + x * 2;
        if (nv21) {
          final src =
              first.rowStride * source.height + sy * first.rowStride + sx * 2;
          bytes[dst] = first.bytes[src];
          bytes[dst + 1] = first.bytes[src + 1];
        } else {
          final u = source.planes[1], v = source.planes[2];
          bytes[dst] = v.bytes[sy * v.rowStride + sx * v.pixelStride];
          bytes[dst + 1] = u.bytes[sy * u.rowStride + sx * u.pixelStride];
        }
      }
    }
  }
  final sharpness = estimateLumaSharpness(luma, w, h);
  // The iOS byte bridge ignores rotation metadata. Rotate BGRA pixels instead.
  if (bgra && source.rotation != 0) {
    final angle = source.rotation;
    if (angle != 90 && angle != 180 && angle != 270) {
      throw ArgumentError('Rotation must be a multiple of 90 degrees');
    }
    final rw = angle == 180 ? w : h;
    final rh = angle == 180 ? h : w;
    final upright = Uint8List(bytes.length);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final dx = angle == 90
            ? h - 1 - y
            : angle == 180
            ? w - 1 - x
            : y;
        final dy = angle == 90
            ? x
            : angle == 180
            ? h - 1 - y
            : w - 1 - x;
        final target = (dy * rw + dx) * 4;
        upright.setRange(target, target + 4, bytes, (y * w + x) * 4);
      }
    }
    return PreparedOcrFrame(upright, rw, rh, true, sharpness);
  }
  return PreparedOcrFrame(bytes, w, h, bgra, sharpness);
}

/// Exact union area: overlapping blocks must not inflate text coverage.
@visibleForTesting
double ocrBoxCoverage(List<Rect> boxes, Rect roi) {
  final clipped = boxes
      .map((b) => b.intersect(roi))
      .where((b) => !b.isEmpty)
      .toList();
  final xs = clipped.expand((b) => [b.left, b.right]).toSet().toList()..sort();
  double area = 0;
  for (var i = 1; i < xs.length; i++) {
    final spans =
        clipped.where((b) => b.left < xs[i] && b.right > xs[i - 1]).toList()
          ..sort((a, b) => a.top.compareTo(b.top));
    double height = 0, end = double.negativeInfinity;
    for (final b in spans) {
      height += math.max(0, b.bottom - math.max(end, b.top));
      end = math.max(end, b.bottom);
    }
    area += (xs[i] - xs[i - 1]) * height;
  }
  return roi.isEmpty ? 0 : area / (roi.width * roi.height);
}
