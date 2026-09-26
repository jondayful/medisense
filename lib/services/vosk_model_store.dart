import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Downloads, validates, and stores the Tagalog Vosk model outside the app
/// bundle. A completed model is never downloaded again.
class VoskModelStore extends ChangeNotifier {
  static const modelName = 'vosk-model-tl-ph-generic-0.6';
  static const modelUrl =
      'https://alphacephei.com/vosk/models/vosk-model-tl-ph-generic-0.6.zip';
  static const minimumFreeBytes = 1536 * 1024 * 1024; // 1.5 GiB
  static const _storageChannel = MethodChannel('medisense/storage');

  VoskModelStore({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;
  http.Client? _activeClient;
  Future<String>? _inFlight;
  Future<String?>? _installedModelCheck;
  String? _validatedModelPath;
  bool _cancelled = false;
  bool _disposed = false;

  int _receivedBytes = 0;
  int? _totalBytes;
  String? _error;

  int get receivedBytes => _receivedBytes;
  int? get totalBytes => _totalBytes;
  double? get progress => _totalBytes == null || _totalBytes == 0
      ? null
      : _receivedBytes / _totalBytes!;
  String? get error => _error;
  bool get isDownloading => _inFlight != null;

  /// Returns the installed model without starting a download. This is used
  /// before presenting download UI, so an existing model never flashes the
  /// download sheet while it is being validated.
  Future<String?> installedModelPath() {
    final cached = _validatedModelPath;
    if (cached != null) return Future<String?>.value(cached);
    return _installedModelCheck ??= _findInstalledModel().whenComplete(() {
      _installedModelCheck = null;
    });
  }

  Future<String?> _findInstalledModel() async {
    final documents = await getApplicationDocumentsDirectory();
    final modelPath = path.join(documents.path, modelName);
    if (!await hasValidModel(modelPath)) return null;
    _validatedModelPath = modelPath;
    return modelPath;
  }

  /// Returns the absolute extracted model directory. It is safe to call at
  /// startup: a valid existing model avoids all network activity.
  Future<String> prepare() => _inFlight ??= _prepare().whenComplete(() {
    _inFlight = null;
    _notifyIfAlive();
  });

  void _notifyIfAlive() {
    if (!_disposed) notifyListeners();
  }

  /// Stops the current HTTP stream. The `.part` archive remains so [prepare]
  /// can resume it using a Range request later.
  void cancel() {
    _cancelled = true;
    _activeClient?.close();
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }

  Future<String> _prepare() async {
    _cancelled = false;
    _error = null;
    final installed = await installedModelPath();
    if (installed != null) return installed;

    final documents = await getApplicationDocumentsDirectory();
    final modelDirectory = Directory(path.join(documents.path, modelName));

    final archive = File(path.join(documents.path, '$modelName.zip'));
    try {
      await _ensureEnoughStorage(documents.path);
      if (!await archive.exists()) {
        await _downloadWithRetries(documents, archive);
      }
      _ensureNotCancelled();
      await compute(_extractArchive, <String, String>{
        'archive': archive.path,
        'documents': documents.path,
        'modelName': modelName,
      });
      if (!await hasValidModel(modelDirectory.path)) {
        throw const VoskModelException('The extracted model is incomplete.');
      }
      // Do not leave a second ~320 MB copy after a successful extraction.
      if (await archive.exists()) await archive.delete();
      _validatedModelPath = modelDirectory.path;
      return modelDirectory.path;
    } on VoskDownloadCancelled {
      rethrow;
    } on FileSystemException catch (error) {
      await _cleanupIncomplete(documents.path, archive.path);
      _error = 'Not enough storage or the model files cannot be written.';
      throw VoskModelException(_error!, cause: error);
    } catch (error) {
      await _cleanupIncomplete(documents.path, archive.path);
      _error = error is VoskModelException
          ? error.message
          : 'Could not download the offline voice package. Check your connection and retry.';
      throw VoskModelException(_error!, cause: error);
    } finally {
      _activeClient?.close();
      _activeClient = null;
    }
  }

  /// Native StatFs is required here: dart:io exposes file metadata, not free
  /// filesystem capacity. The headroom covers archive, staging, and final data.
  Future<void> _ensureEnoughStorage(String documentsPath) async {
    final available = await _storageChannel.invokeMethod<int>(
      'availableBytes',
      <String, String>{'path': documentsPath},
    );
    if (available == null) {
      throw const VoskModelException(
        'Unable to check free storage for the offline voice package.',
      );
    }
    if (available < minimumFreeBytes) {
      throw VoskInsufficientStorageException(
        availableBytes: available,
        requiredBytes: minimumFreeBytes,
      );
    }
  }

  Future<void> _cleanupIncomplete(
    String documentsPath,
    String archivePath,
  ) async {
    final partial = File('$archivePath.part');
    final staging = Directory(
      path.join(documentsPath, '$modelName.extracting'),
    );
    try {
      if (await partial.exists()) await partial.delete();
      final archive = File(archivePath);
      if (await archive.exists()) await archive.delete();
      if (await staging.exists()) await staging.delete(recursive: true);
    } on FileSystemException {
      // Preserve the original download/extraction error as the actionable one.
    }
  }

  Future<void> _downloadWithRetries(Directory documents, File archive) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _downloadOnce(documents, archive);
        return;
      } on VoskDownloadCancelled {
        rethrow;
      } catch (error) {
        lastError = error;
        if (attempt < 2) {
          await Future<void>.delayed(Duration(seconds: attempt + 1));
        }
      }
    }
    throw VoskModelException(
      'Download failed after 3 attempts.',
      cause: lastError,
    );
  }

  Future<void> _downloadOnce(Directory documents, File archive) async {
    final partial = File('${archive.path}.part');
    var resumeFrom = await partial.exists() ? await partial.length() : 0;
    _receivedBytes = resumeFrom;
    _totalBytes = null;
    _notifyIfAlive();

    final request = http.Request('GET', Uri.parse(modelUrl));
    if (resumeFrom > 0) {
      request.headers[HttpHeaders.rangeHeader] = 'bytes=$resumeFrom-';
    }
    final client = _activeClient = _clientFactory();
    try {
      final response = await client.send(request);
      _ensureNotCancelled();
      if (response.statusCode == HttpStatus.ok && resumeFrom > 0) {
        // Server ignored Range; restart instead of corrupting the archive.
        await partial.delete();
        resumeFrom = 0;
        _receivedBytes = 0;
        client.close();
        return await _downloadOnce(documents, archive);
      }
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw VoskModelException(
          'Server returned HTTP ${response.statusCode}.',
        );
      }

      _totalBytes = _contentLength(response, resumeFrom);
      _notifyIfAlive();
      final sink = partial.openWrite(mode: FileMode.append);
      try {
        await for (final bytes in response.stream) {
          _ensureNotCancelled();
          sink.add(bytes);
          _receivedBytes += bytes.length;
          _notifyIfAlive();
        }
      } finally {
        await sink.close();
      }
      _ensureNotCancelled();
      if (_totalBytes != null && _receivedBytes != _totalBytes) {
        throw const VoskModelException(
          'Download ended before the archive was complete.',
        );
      }
      await partial.rename(archive.path);
    } finally {
      client.close();
      if (identical(_activeClient, client)) _activeClient = null;
    }
  }

  int? _contentLength(http.StreamedResponse response, int resumeFrom) {
    final range = response.headers[HttpHeaders.contentRangeHeader];
    final total = range == null
        ? null
        : RegExp(r'/([0-9]+)$').firstMatch(range)?.group(1);
    return total == null
        ? response.contentLength == null
              ? null
              : resumeFrom + response.contentLength!
        : int.tryParse(total);
  }

  void _ensureNotCancelled() {
    if (_cancelled) throw const VoskDownloadCancelled();
  }

  /// Checks essential files, not merely the directory name left by a failed
  /// extraction. Vosk variants differ in graph details, so require any FST.
  static Future<bool> hasValidModel(String absolutePath) async {
    final root = Directory(absolutePath);
    if (!await root.exists()) return false;
    final required = <String>[
      path.join(absolutePath, 'am', 'final.mdl'),
      path.join(absolutePath, 'conf', 'model.conf'),
    ];
    if (!(await Future.wait(
      required.map((file) => File(file).exists()),
    )).every((it) => it)) {
      return false;
    }
    return Directory(path.join(absolutePath, 'graph'))
        .list(recursive: true)
        .any((entity) => entity is File && entity.path.endsWith('.fst'));
  }
}

class VoskModelException implements Exception {
  const VoskModelException(this.message, {this.cause});
  final String message;
  final Object? cause;
  @override
  String toString() => message;
}

class VoskInsufficientStorageException extends VoskModelException {
  VoskInsufficientStorageException({
    required this.availableBytes,
    required this.requiredBytes,
  }) : super(
         'Not enough free storage for offline voice. Free at least '
         '${_gigabytes(requiredBytes)} GB, then try again.',
       );

  final int availableBytes;
  final int requiredBytes;

  static String _gigabytes(int bytes) =>
      (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1);
}

class VoskDownloadCancelled implements Exception {
  const VoskDownloadCancelled();
}

/// Top-level for [compute]. Extraction uses a staging directory and rejects
/// zip-slip paths before atomically moving the complete model into place.
Future<void> _extractArchive(Map<String, String> args) async {
  final archiveFile = File(args['archive']!);
  final documents = args['documents']!;
  final modelName = args['modelName']!;
  final target = Directory(path.join(documents, modelName));
  final staging = Directory('${target.path}.extracting');
  if (await staging.exists()) await staging.delete(recursive: true);
  await staging.create(recursive: true);

  try {
    // File-backed input avoids duplicating the entire ~320 MB ZIP in isolate
    // memory before decompression. Individual entries are decoded as needed.
    final input = InputFileStream(archiveFile.path);
    try {
      final zip = ZipDecoder().decodeBuffer(input, verify: true);
      for (final entry in zip) {
        if (!entry.isFile) continue;
        final parts = path.split(path.normalize(entry.name));
        if (parts.isEmpty ||
            parts.first != modelName ||
            parts.any((part) => part == '..')) {
          throw const VoskModelException(
            'Archive contains an invalid model path.',
          );
        }
        final destination = path.join(
          staging.path,
          path.joinAll(parts.skip(1)),
        );
        if (!path.isWithin(staging.path, destination)) {
          throw const VoskModelException(
            'Archive contains an unsafe file path.',
          );
        }
        final file = File(destination);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.content as List<int>, flush: false);
      }
    } finally {
      await input.close();
    }
    if (!await VoskModelStore.hasValidModel(staging.path)) {
      throw const VoskModelException(
        'Archive does not contain a valid Vosk model.',
      );
    }
    if (await target.exists()) await target.delete(recursive: true);
    await staging.rename(target.path);
  } catch (_) {
    if (await staging.exists()) await staging.delete(recursive: true);
    rethrow;
  }
}
