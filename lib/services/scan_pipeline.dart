import 'dart:io';
import 'dart:isolate';
import 'dart:async';

import 'package:image/image.dart' as img;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';

import 'medicine_label_parser.dart';

/// A small, device-local medicine catalog entry. The catalog is deliberately
/// data-driven so it can later be populated from a bundled JSON/SQLite file
/// without changing the scan flow.
class MedicineCatalogEntry {
  final String name;
  final String? dosage;
  final String? form;
  final List<String> aliases;
  final List<String> barcodes;

  const MedicineCatalogEntry({
    required this.name,
    this.dosage,
    this.form,
    this.aliases = const [],
    this.barcodes = const [],
  });
}

class MedicineCatalogMatch {
  final MedicineCatalogEntry entry;
  final double confidence;

  const MedicineCatalogMatch(this.entry, this.confidence);
}

/// Performs deterministic local validation. It never uses the network and it
/// never creates a medicine from a barcode that is not in the catalog.
class MedicineCatalogRepository {
  final List<MedicineCatalogEntry> entries;

  const MedicineCatalogRepository({this.entries = const []});

  MedicineCatalogMatch? findByBarcode(String barcode) {
    final normalized = _normalize(barcode);
    if (normalized.isEmpty) return null;
    for (final entry in entries) {
      if (entry.barcodes.any((value) => _normalize(value) == normalized)) {
        return MedicineCatalogMatch(entry, 0.99);
      }
    }
    return null;
  }

  MedicineCatalogMatch? findByText(String text) {
    final normalized = _normalize(text);
    if (normalized.isEmpty) return null;
    MedicineCatalogMatch? best;
    for (final entry in entries) {
      final candidates = [entry.name, ...entry.aliases];
      for (final candidate in candidates) {
        final alias = _normalize(candidate);
        if (alias.isEmpty) continue;
        final confidence = normalized.contains(alias)
            ? 0.96
            : _tokenSimilarity(normalized, alias);
        if (confidence > 0 && (best == null || confidence > best.confidence)) {
          best = MedicineCatalogMatch(entry, confidence);
        }
      }
    }
    return best;
  }

  String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  double _tokenSimilarity(String text, String alias) {
    final words = text.split(' ');
    final aliasWords = alias.split(' ');
    if (aliasWords.isEmpty) return 0;
    var matched = 0;
    for (final word in aliasWords) {
      if (words.any((candidate) => candidate == word)) matched++;
    }
    return matched == aliasWords.length ? 0.82 : 0;
  }
}

/// Barcode analysis for a captured image. MobileScanner delegates to the
/// native ML Kit/Apple Vision implementations and does not require network.
class BarcodeScanService {
  BarcodeScanService({MedicineCatalogRepository? catalog})
    : catalog = catalog ?? const MedicineCatalogRepository();

  final MedicineCatalogRepository catalog;
  final MobileScannerController _controller = MobileScannerController(
    autoStart: false,
    formats: [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.code128,
      BarcodeFormat.qrCode,
      BarcodeFormat.dataMatrix,
    ],
  );

  /// The default scanner has no local barcode records. Avoid invoking native
  /// image analysis when there is nothing it can possibly match.
  bool get canMatch => catalog.entries.isNotEmpty;

  Future<MedicineCatalogMatch?> matchImage(String path) async {
    final capture = await _controller.analyzeImage(path);
    if (capture == null) return null;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.trim().isEmpty) continue;
      final match = catalog.findByBarcode(raw);
      if (match != null) return match;
    }
    return null;
  }

  void dispose() => _controller.dispose();
}

/// Prepares bounded OCR images and applies a second-pass enhancement only
/// when the first read is weak. All bitmap work stays in a persistent isolate.
class ImagePreprocessor {
  final Map<String, Future<String?>> _pending = {};
  final Set<String> _generatedPaths = {};
  Isolate? _worker;
  ReceivePort? _responses;
  SendPort? _requests;
  Future<void>? _starting;
  Future<String>? _cacheDirectory;
  final Map<int, Completer<String?>> _jobs = {};
  int _nextJob = 0;
  bool _disposed = false;

  /// Decode, bake orientation, crop and resize on a persistent worker before
  /// either native OCR engine sees the image. Only paths cross isolates, so a
  /// full sensor JPEG is never copied into the UI isolate's heap.
  Future<String?> prepareForOcr(String sourcePath, {bool centerCrop = true}) =>
      _process(sourcePath, enhance: false, centerCrop: centerCrop);

  Future<String?> getEnhancedImage(String sourcePath) =>
      _process(sourcePath, enhance: true, centerCrop: false);

  /// Crop the visible viewfinder region on the image worker before OCR.
  /// [roi] uses fractions of the displayed camera preview in upright image
  /// coordinates. Only the file path crosses the isolate boundary.
  Future<String?> cropViewfinderRoi(String sourcePath, ScanRoi roi) =>
      _process(sourcePath, enhance: false, centerCrop: false, roi: roi);

  Future<String?> enhanceForOcr(String sourcePath) =>
      getEnhancedImage(sourcePath);

  Future<String?> _process(
    String path, {
    required bool enhance,
    required bool centerCrop,
    ScanRoi? roi,
  }) async {
    if (_disposed) return null;
    final key = '$path|$enhance|$centerCrop|${roi?.cacheKey ?? ''}';
    return _pending.putIfAbsent(key, () async {
      try {
        await (_starting ??= _startWorker());
        if (_requests == null || _disposed) return null;
        final id = ++_nextJob;
        final reply = Completer<String?>();
        _jobs[id] = reply;
        final cacheDirectory = await (_cacheDirectory ??= _resolveCachePath());
        _requests!.send([
          id,
          path,
          enhance,
          centerCrop,
          cacheDirectory,
          roi?.toList(),
        ]);
        final result = await reply.future;
        if (result != null) _generatedPaths.add(result);
        return result;
      } catch (_) {
        return null;
      }
    });
  }

  Future<String> _resolveCachePath() async {
    try {
      return (await getTemporaryDirectory()).path;
    } catch (_) {
      return Directory.systemTemp.path;
    }
  }

  Future<void> _startWorker() async {
    final ready = Completer<SendPort>();
    final port = ReceivePort();
    _responses = port;
    port.listen((dynamic message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message == null) {
        for (final job in _jobs.values) {
          if (!job.isCompleted) job.complete(null);
        }
        _jobs.clear();
      } else if (message is List && message.length == 2) {
        final job = _jobs.remove(message[0]);
        job?.complete(message[1] as String?);
      }
    });
    _worker = await Isolate.spawn(
      _imageWorker,
      port.sendPort,
      errorsAreFatal: true,
      onExit: port.sendPort,
    );
    _requests = await ready.future;
  }

  Future<void> release(String sourcePath) async {
    if (_generatedPaths.contains(sourcePath)) {
      await releaseGenerated(sourcePath);
    }
    final keys = _pending.keys
        .where((key) => key.startsWith('$sourcePath|'))
        .toList();
    for (final key in keys) {
      final generated = await _pending.remove(key);
      if (generated == null) continue;
      _generatedPaths.remove(generated);
      try {
        await File(generated).delete();
      } catch (_) {}
    }
  }

  /// Deletes one derived image only after its native OCR future has completed.
  Future<void> releaseGenerated(String generatedPath) async {
    final matchingJobs = <String>[];
    for (final entry in _pending.entries) {
      if (await entry.value == generatedPath) matchingJobs.add(entry.key);
    }
    for (final key in matchingJobs) {
      _pending.remove(key);
    }
    if (!_generatedPaths.remove(generatedPath)) return;
    try {
      final file = File(generatedPath);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Captures live in the platform cache; remove only our derived files when
  /// the scan screen closes, after every OCR consumer has finished with them.
  Future<void> dispose() async {
    _disposed = true;
    await Future.wait(_pending.values);
    _worker?.kill(priority: Isolate.immediate);
    _responses?.close();
    await Future.wait(
      _generatedPaths.map((path) async {
        try {
          await File(path).delete();
        } catch (_) {
          // Cache cleanup must never affect a scan result.
        }
      }),
    );
    _generatedPaths.clear();
    _pending.clear();
  }
}

/// A normalized rectangle measured against the camera preview and reticle.
class ScanRoi {
  const ScanRoi(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;

  String get cacheKey => '$left,$top,$width,$height';
  List<double> toList() => [left, top, width, height];
}

void _imageWorker(SendPort host) {
  final requests = ReceivePort();
  host.send(requests.sendPort);
  requests.listen((dynamic message) async {
    final job = message as List;
    String? output;
    try {
      output = await _transformOcrFile(
        job[1] as String,
        enhance: job[2] as bool,
        centerCrop: job[3] as bool,
        cacheDirectory: job[4] as String,
        roi: (job[5] as List?)?.cast<double>(),
      );
    } catch (_) {}
    host.send([job[0], output]);
  });
}

Future<String?> _transformOcrFile(
  String sourcePath, {
  required bool enhance,
  required bool centerCrop,
  required String cacheDirectory,
  List<double>? roi,
}) async {
  final decoded = img.decodeImage(await File(sourcePath).readAsBytes());
  if (decoded == null) return null;

  // Bake EXIF orientation before OCR. Camera output otherwise differs by
  // platform and can make rows appear sideways to a native engine.
  var working = img.bakeOrientation(decoded);
  if (roi != null) {
    final left = (roi[0].clamp(0.0, 1.0) * working.width).round();
    final top = (roi[1].clamp(0.0, 1.0) * working.height).round();
    final right = ((roi[0] + roi[2]).clamp(0.0, 1.0) * working.width).round();
    final bottom = ((roi[1] + roi[3]).clamp(0.0, 1.0) * working.height).round();
    if (right <= left || bottom <= top) return null;
    working = img.copyCrop(working, left, top, right - left, bottom - top);
  }
  if (centerCrop) {
    // The overlay is square. A generous square crop keeps the medicine name
    // and strength near its edge while excluding shelves, hands and page
    // margins. Prescription-classified captures keep the whole page.
    final side =
        ((working.width < working.height ? working.width : working.height) *
                0.90)
            .round();
    working = img.copyCrop(
      working,
      (working.width - side) ~/ 2,
      (working.height - side) ~/ 2,
      side,
      side,
    );
  }
  const maxSide = 1280;
  final longestSide = working.width > working.height
      ? working.width
      : working.height;
  if (longestSide > maxSide) {
    working = img.copyResize(
      working,
      width: (working.width * maxSide / longestSide).round(),
      height: (working.height * maxSide / longestSide).round(),
      interpolation: img.Interpolation.linear,
    );
  }

  if (enhance) {
    img.grayscale(working);
    _applyClahe(working);
  }
  final output = File(
    '$cacheDirectory${Platform.pathSeparator}'
    'medisense_ocr_${DateTime.now().microsecondsSinceEpoch}'
    '_${_nextWorkerFileId++}.jpg',
  );
  try {
    await output.writeAsBytes(img.encodeJpg(working, quality: 90));
    return output.path;
  } catch (_) {
    try {
      if (await output.exists()) await output.delete();
    } catch (_) {}
    rethrow;
  }
}

int _nextWorkerFileId = 0;

/// Small 8x8-tile CLAHE. It improves faded text and uneven illumination while
/// remaining linear in pixels; it is deliberately run only on the fallback.
void _applyClahe(img.Image image) {
  // image 3.x exposes a view of its RGBA backing store. Read and write pixels
  // in place, avoiding millions of getPixel/setPixel calls and another frame.
  final pixels = image.getBytes();
  const tiles = 8;
  final tileWidth = (image.width / tiles).ceil();
  final tileHeight = (image.height / tiles).ceil();
  for (var ty = 0; ty < tiles; ty++) {
    for (var tx = 0; tx < tiles; tx++) {
      final left = tx * tileWidth;
      final top = ty * tileHeight;
      final right = (left + tileWidth).clamp(0, image.width);
      final bottom = (top + tileHeight).clamp(0, image.height);
      if (left >= right || top >= bottom) continue;
      final histogram = List<int>.filled(256, 0);
      for (var y = top; y < bottom; y++) {
        for (var x = left; x < right; x++) {
          histogram[pixels[(y * image.width + x) * 4]]++;
        }
      }
      final count = (right - left) * (bottom - top);
      final limit = (count * 2 ~/ 256).clamp(1, count);
      var excess = 0;
      for (var i = 0; i < 256; i++) {
        if (histogram[i] > limit) {
          excess += histogram[i] - limit;
          histogram[i] = limit;
        }
      }
      final increment = excess ~/ 256;
      final remainder = excess % 256;
      for (var i = 0; i < 256; i++) {
        histogram[i] += increment + (i < remainder ? 1 : 0);
      }
      final lut = List<int>.filled(256, 0);
      var cumulative = 0;
      for (var i = 0; i < 256; i++) {
        cumulative += histogram[i];
        lut[i] = (255 * cumulative / count).round();
      }
      for (var y = top; y < bottom; y++) {
        for (var x = left; x < right; x++) {
          final offset = (y * image.width + x) * 4;
          final value = lut[pixels[offset]];
          pixels[offset] = value;
          pixels[offset + 1] = value;
          pixels[offset + 2] = value;
        }
      }
    }
  }
  // Remove isolated dark sensor specks and strengthen faint strokes. Keep a
  // gray edge rather than hard black/white output so embossed text survives.
  for (var y = 1; y < image.height - 1; y++) {
    for (var x = 1; x < image.width - 1; x++) {
      final offset = (y * image.width + x) * 4;
      final center = pixels[offset];
      final neighbors =
          pixels[offset - 4] +
          pixels[offset + 4] +
          pixels[offset - image.width * 4] +
          pixels[offset + image.width * 4];
      final average = neighbors ~/ 4;
      final value = center < 45 && average > 210
          ? average
          : center < average - 12 && center > average - 40
          ? (center * 0.78).round()
          : center;
      if (value == center) continue;
      pixels[offset] = value;
      pixels[offset + 1] = value;
      pixels[offset + 2] = value;
    }
  }
}

/// Prevents repeated automatic work when the camera keeps returning the same
/// label. This is independent of the camera and easy to unit test.
class ScanFrameGate {
  String? _lastText;
  DateTime? _lastAcceptedAt;

  bool shouldProcess(String recognizedText, DateTime now) {
    final normalized = recognizedText
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase();
    if (normalized.isEmpty) return true;
    if (_lastText == normalized &&
        _lastAcceptedAt != null &&
        now.difference(_lastAcceptedAt!) < const Duration(seconds: 2)) {
      return false;
    }
    _lastText = normalized;
    _lastAcceptedAt = now;
    return true;
  }

  void reset() {
    _lastText = null;
    _lastAcceptedAt = null;
  }
}

/// Requires two consecutive, matching medicine reads before an automatic
/// scan opens confirmation. OCR noise outside the parsed name and strength
/// does not reset the candidate.
class ScanResultStabilityGate {
  String? _candidate;
  int _consecutiveReads = 0;

  bool accept(MedicineLabelResult? result) {
    if (result == null) {
      reset();
      return false;
    }
    final key = '${result.name}|${result.dosage}'
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (key != _candidate) {
      _candidate = key;
      _consecutiveReads = 1;
      return false;
    }
    _consecutiveReads++;
    return _consecutiveReads >= 2;
  }

  /// Requires the same set of independently read prescription rows twice.
  /// Sorting makes harmless OCR row-order changes stable while retaining each
  /// medicine's name and strength as part of the safety key.
  bool acceptBatch(Iterable<MedicineLabelResult> results) {
    final keys =
        results
            .map(
              (result) => '${result.name}|${result.dosage}'
                  .toLowerCase()
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim(),
            )
            .toList()
          ..sort();
    if (keys.length < 2 || keys.any((key) => key == '|')) {
      reset();
      return false;
    }
    final key = keys.join('||');
    if (key != _candidate) {
      _candidate = key;
      _consecutiveReads = 1;
      return false;
    }
    _consecutiveReads++;
    return _consecutiveReads >= 2;
  }

  void reset() {
    _candidate = null;
    _consecutiveReads = 0;
  }
}

/// Optional platform AI seam. The default implementation is intentionally a
/// no-op: unsupported Gemini Nano/Apple devices must never block scanning.
abstract class OptionalScanAiEnhancer {
  Future<MedicineLabelResult?> enhance({
    required String rawText,
    required MedicineLabelResult result,
  });
}

class NoopScanAiEnhancer implements OptionalScanAiEnhancer {
  const NoopScanAiEnhancer();

  @override
  Future<MedicineLabelResult?> enhance({
    required String rawText,
    required MedicineLabelResult result,
  }) async => null;
}
