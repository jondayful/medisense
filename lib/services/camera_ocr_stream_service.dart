import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

enum ScanHint { noTextFound, moveCloser, moveFurther, holdSteady }

/// Owns the recognizer, but not [camera]. Initialize the camera with
/// ResolutionPreset.veryHigh (1080p stills), NV21 on Android or BGRA8888 on iOS.
/// YUV420 Android streams are also supported, including padded pixel strides.
/// Preview OCR never touches disk. Only the final takePicture creates a file;
/// ownership of that file passes to [onCapture]. Capture pauses the stream:
/// call startStream again to scan another label. Await dispose before disposing
/// the camera. Lifecycle methods must not be awaited from synchronous callbacks.
class CameraOcrStreamService {
  CameraOcrStreamService({
    required this.camera,
    required this.onHint,
    required this.onCapture,
    required this.onError,
    this.onText,
    this.maxDimension = 1280,
    this.minSharpness = 100,
    this.minTextCoverageForGuidance = .03,
    this.frameInterval = const Duration(milliseconds: 350),
    this.hintInterval = const Duration(seconds: 3),
  }) {
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
  final int maxDimension;

  /// Variance of the luminance Laplacian; calibrate on target devices.
  final double minSharpness;

  /// Text boxes are much smaller than the physical label, so this is only a
  /// framing hint threshold; it must never block an otherwise stable capture.
  final double minTextCoverageForGuidance;
  final Duration frameInterval;
  final Duration hintInterval;
  final TextRecognizer _recognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );
  final Stopwatch _clock = Stopwatch()..start();
  Future<void> _lifecycle = Future<void>.value();
  Future<void>? _frame;
  Future<void>? _disposal;
  bool _running = false;
  bool _disposed = false;
  bool _focusExposureLocked = false;
  int _generation = 0;
  Duration _lastFrame = Duration.zero;
  Duration _lastText = Duration.zero;
  Duration? _lastHint;
  String? _stableText;
  Rect? _stableBounds;
  int _stableFrames = 0;

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
    _stableFrames = 0;
    _stableText = null;
    _stableBounds = null;
    _focusExposureLocked = false;
    await _unlockFocusAndExposure();
    _running = true;
    final generation = ++_generation;
    try {
      await camera.startImageStream((image) {
        if (!_running ||
            generation != _generation ||
            _frame != null ||
            _clock.elapsed - _lastFrame < frameInterval) {
          return;
        }
        _lastFrame = _clock.elapsed;
        _frame = _process(image, generation).whenComplete(() => _frame = null);
      });
    } catch (_) {
      _running = false;
      rethrow;
    }
  });

  Future<void> stopStream() {
    _running = false;
    ++_generation;
    return _serialize(() async {
      // A queued start may have run since stop was requested.
      _running = false;
      ++_generation;
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
      await _recognizer.close();
      _clock.stop();
    }
  }

  bool _current(int generation) =>
      !_disposed && _running && generation == _generation;

  void _hint(ScanHint hint) {
    if (_lastHint != null &&
        _clock.elapsed - _lastHint! < hintInterval &&
        hint != ScanHint.holdSteady) {
      return;
    }
    _lastHint = _clock.elapsed;
    onHint(hint);
  }

  Future<void> _process(CameraImage image, int generation) async {
    try {
      final rotation = _rotation();
      // Packing and resize run off the UI isolate. Only one frame is in flight;
      // new camera frames are dropped rather than queued behind native OCR.
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
          : await compute(
              prepareOcrFrame,
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
        _stableFrames = 0;
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
      // Lock once useful text fills the target area. This prevents autofocus
      // and auto-exposure from hunting while the two-frame stability check runs.
      if (!_focusExposureLocked && coverage >= minTextCoverageForGuidance) {
        _focusExposureLocked = true;
        unawaited(_lockFocusAndExposure());
      }
      final bounds = boxes.reduce((a, b) => a.expandToInclude(b));
      final key = text.text
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
          .trim();
      final stable =
          _similarText(key, _stableText) &&
          _stableBounds != null &&
          (bounds.center - _stableBounds!.center).distance <
              size.shortestSide * .08 &&
          (bounds.width - _stableBounds!.width).abs() < size.width * .12 &&
          (bounds.height - _stableBounds!.height).abs() < size.height * .12;
      _stableFrames = stable ? _stableFrames + 1 : 1;
      _stableText = key;
      _stableBounds = bounds;
      // Two adjacent consistent reads are enough when they contain meaningful
      // text or a sharp frame. Sharpness remains a quality guard for tiny OCR.
      final captureReady =
          _stableFrames >= 2 &&
          (coverage >= minTextCoverageForGuidance ||
              frame.sharpness >= minSharpness) &&
          _hasMedicineSignal(text.text);
      if (!captureReady) {
        // Distance hints are guidance only. They are suppressed while the
        // text and position are settling, and never gate automatic capture.
        if (!stable) {
          if (clippedAtEdge) {
            _hint(ScanHint.moveFurther);
          } else if (coverage < minTextCoverageForGuidance) {
            _hint(ScanHint.moveCloser);
          }
        }
        return;
      }
      _hint(ScanHint.holdSteady);
      if (!_current(generation)) return;
      await camera.stopImageStream();
      if (!_current(generation)) return;
      final capture = await camera.takePicture();
      if (!_current(generation)) {
        await File(capture.path).delete();
        return;
      }
      _running = false;
      onCapture(capture);
    } catch (error, stack) {
      if (!_disposed && generation == _generation) {
        _stableFrames = 0;
        if (!camera.value.isStreamingImages) _running = false;
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

  Future<void> _lockFocusAndExposure() async {
    try {
      await camera.setFocusMode(FocusMode.locked);
      await camera.setExposureMode(ExposureMode.locked);
    } on Object {
      // Some camera backends do not support locking. OCR still proceeds.
    }
  }

  Future<void> _unlockFocusAndExposure() async {
    try {
      await camera.setFocusMode(FocusMode.auto);
      await camera.setExposureMode(ExposureMode.auto);
    } on Object {
      // Unsupported controls leave the camera in the backend's default mode.
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

  bool _similarText(String current, String? previous) {
    if (previous == null || current.isEmpty || previous.isEmpty) return false;
    if (current == previous) return true;
    final left = previous.length > 180 ? previous.substring(0, 180) : previous;
    final right = current.length > 180 ? current.substring(0, 180) : current;
    final longest = math.max(left.length, right.length);
    if (longest < 4 || (left.length - right.length).abs() / longest > .15) {
      return false;
    }

    var previousRow = List<int>.generate(left.length + 1, (i) => i);
    for (var row = 1; row <= right.length; row++) {
      final currentRow = List<int>.filled(left.length + 1, row);
      var rowMinimum = row;
      for (var column = 1; column <= left.length; column++) {
        final substitution =
            previousRow[column - 1] +
            (right.codeUnitAt(row - 1) == left.codeUnitAt(column - 1) ? 0 : 1);
        currentRow[column] = math.min(
          substitution,
          math.min(previousRow[column] + 1, currentRow[column - 1] + 1),
        );
        if (currentRow[column] < rowMinimum) {
          rowMinimum = currentRow[column];
        }
      }
      if (rowMinimum > math.max(2, (longest * .15).round())) return false;
      previousRow = currentRow;
    }
    return previousRow[left.length] <= math.max(2, (longest * .15).round());
  }

  bool _hasMedicineSignal(String text) => RegExp(
    r'\b\d+(?:[.,]\d+)?\s*(?:mg|mcg|μg|ug|g|ml|mL|iu|units?)\b',
    caseSensitive: false,
  ).hasMatch(text);
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
  double sum = 0, squares = 0;
  var count = 0;
  for (var y = 1; y < h - 1; y += 2) {
    for (var x = 1; x < w - 1; x += 2) {
      final i = y * w + x;
      final value =
          luma[i - 1] + luma[i + 1] + luma[i - w] + luma[i + w] - 4 * luma[i];
      sum += value;
      squares += value * value;
      count++;
    }
  }
  final sharpness = count == 0
      ? 0.0
      : math.max(0.0, squares / count - math.pow(sum / count, 2));
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
