import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_vision_service.dart';
import 'medication_database_service.dart';
import 'medicine_label_parser.dart';
import 'ocr_coordinator_exceptions.dart';
import 'ocr_text_cleanup.dart';

enum OcrResultSource { onDeviceMlKit, cloudVision }

/// Best-effort scan result. A scan always returns the strongest available
/// local result; unavailable network, cloud errors, and quota limits are silent.
class OcrScanResult {
  const OcrScanResult({
    required this.rawText,
    required this.medicine,
    required this.medicines,
    required this.isCatalogVerified,
    required this.isComplete,
    required this.localWasUnclear,
    required this.freeQuotaExceeded,
    required this.source,
  });

  final String rawText;
  final ParsedMedicine? medicine;
  final List<ParsedMedicine> medicines;
  final bool isCatalogVerified;
  final bool isComplete;
  final bool localWasUnclear;
  final bool freeQuotaExceeded;
  final OcrResultSource source;
}

/// Runs on-device Latin ML Kit first, then silently tries Cloud Vision only
/// when the local result is incomplete or low-confidence. Reuse one instance
/// for the scanner lifecycle and call [dispose] when it ends.
///
/// Free-tier usage is stored locally as requested. For billing-grade quota
/// enforcement, mirror this limit in a trusted backend.
class OcrCoordinatorService {
  OcrCoordinatorService({
    required this.parser,
    MedicationDatabaseService? medicationDatabase,
    CloudVisionService? cloudVision,
    TextRecognizer? textRecognizer,
    Connectivity? connectivity,
    Future<SharedPreferences> Function()? loadPreferences,
    DateTime Function()? now,
    this.freeDailyCloudLimit = 3,
  }) : _medicationDatabase =
           medicationDatabase ?? MedicationDatabaseService.instance,
       _cloudVision = cloudVision ?? CloudVisionService(),
       _ownsCloudVision = cloudVision == null,
       _textRecognizer =
           textRecognizer ??
           TextRecognizer(script: TextRecognitionScript.latin),
       _ownsTextRecognizer = textRecognizer == null,
       _checkConnectivity = (connectivity ?? Connectivity()).checkConnectivity,
       _loadPreferences = loadPreferences ?? SharedPreferences.getInstance,
       _now = now ?? DateTime.now {
    if (freeDailyCloudLimit < 1) {
      throw ArgumentError.value(
        freeDailyCloudLimit,
        'freeDailyCloudLimit',
        'Must be at least one.',
      );
    }
  }

  static const defaultFreeDailyCloudLimit = 3;
  static Future<void> _quotaQueue = Future<void>.value();

  final MedicineLabelParser parser;
  final MedicationDatabaseService _medicationDatabase;
  final CloudVisionService _cloudVision;
  final bool _ownsCloudVision;
  final TextRecognizer _textRecognizer;
  final bool _ownsTextRecognizer;
  final Future<List<ConnectivityResult>> Function() _checkConnectivity;
  final Future<SharedPreferences> Function() _loadPreferences;
  final DateTime Function() _now;
  final int freeDailyCloudLimit;

  Future<void> _scanQueue = Future<void>.value();
  Future<void>? _disposeFuture;
  bool _disposed = false;

  /// Returns local ML Kit data if it is the best result, including when
  /// offline. No connectivity or quota messaging escapes this service.
  Future<OcrScanResult> processPrescriptionImage({
    required String imagePath,
    required String userId,
    required String userTier,
    bool allowCloudFallback = true,
    bool labelFirst = false,
    OcrScanResult? localResult,
  }) {
    if (_disposed) {
      return Future.error(StateError('OCR coordinator is disposed.'));
    }
    final scan = _scanQueue.then(
      (_) => _processPrescriptionImage(
        imagePath: imagePath,
        userId: userId,
        userTier: userTier,
        allowCloudFallback: allowCloudFallback,
        labelFirst: labelFirst,
        localResult: localResult,
      ),
    );
    _scanQueue = scan.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return scan;
  }

  Future<OcrScanResult> _processPrescriptionImage({
    required String imagePath,
    required String userId,
    required String userTier,
    required bool allowCloudFallback,
    required bool labelFirst,
    required OcrScanResult? localResult,
  }) async {
    var localText = localResult?.rawText ?? '';
    if (localResult == null) {
      try {
        final recognized = await _textRecognizer.processImage(
          InputImage.fromFilePath(imagePath),
        );
        // Keep ML Kit geometry through local parsing so labels arranged in
        // columns are reconstructed in visual reading order.
        localText = parser.layoutRecognizedText(recognized);
      } on Object {
        // A platform/OCR failure is treated like an unclear local read. The
        // cloud path remains optional and any failure still returns local data.
      }
    }

    final local = await _assess(localText, labelFirst: labelFirst);
    final assessedLocalResult = _toResult(
      local,
      source: OcrResultSource.onDeviceMlKit,
      localWasUnclear: !local.complete,
    );
    if (!allowCloudFallback || local.complete || !_cloudVision.isConfigured) {
      return assessedLocalResult;
    }

    if (!await _hasNetwork()) return assessedLocalResult;

    final tier = _tier(userTier);
    if (tier == null) return assessedLocalResult;
    if (!tier) {
      try {
        await _reserveFreeScan(userId);
      } on CloudQuotaExceededException {
        return _toResult(
          local,
          source: OcrResultSource.onDeviceMlKit,
          localWasUnclear: true,
          freeQuotaExceeded: true,
        );
      } on Object {
        // If local quota storage fails closed, keep the scan offline/local.
        return assessedLocalResult;
      }
    }

    try {
      final cloudText = await _cloudVision.recognizeDocument(imagePath);
      if (cloudText.trim().isEmpty) return assessedLocalResult;
      final cloud = await _assess(cloudText, labelFirst: labelFirst);
      if (!_isBetter(cloud, local)) return assessedLocalResult;
      return _toResult(
        cloud,
        source: OcrResultSource.cloudVision,
        localWasUnclear: true,
      );
    } on Object {
      // Cloud Vision is opportunistic. Timeouts and service errors never turn
      // an otherwise usable offline scan into a failure or user alert.
      return assessedLocalResult;
    }
  }

  Future<_Assessment> _assess(String rawText, {bool labelFirst = false}) async {
    if (rawText.trim().isEmpty) return _Assessment.empty(rawText);
    final cleanedText = const OcrTextCleanup().clean(rawText).text;

    final allStructured = labelFirst
        ? const <ParsedMedicine>[]
        : parser.parseAllStructured(cleanedText);
    final fallback = allStructured.isEmpty
        ? labelFirst
              ? parser.parsePackageStructured(cleanedText)
              : parser.parseStructured(cleanedText)
        : null;
    final medicines = allStructured.isNotEmpty
        ? allStructured
        : fallback == null
        ? const <ParsedMedicine>[]
        : <ParsedMedicine>[fallback];
    if (medicines.isEmpty) {
      return _Assessment(
        rawText: rawText,
        medicine: fallback,
        medicines: medicines,
        verifiedCount: 0,
        complete: false,
        quality: 0,
      );
    }

    var verifiedCount = 0;
    if (!labelFirst) {
      try {
        for (final medicine in medicines) {
          if (medicine.medicineName.trim().isEmpty) continue;
          final candidates = await _medicationDatabase.matchCandidates(
            medicine.medicineName,
          );
          if (candidates.isNotEmpty) verifiedCount++;
        }
      } on Object {
        // The text is still returned for review if a damaged or absent catalog
        // prevents verification; it simply cannot qualify as complete.
      }
    }

    final allVerified = verifiedCount == medicines.length;
    final allConfident = medicines.every((m) => m.isHighConfidence);
    final allHaveDoseDetails = medicines.every(
      (m) => m.strength.trim().isNotEmpty || m.frequency.trim().isNotEmpty,
    );
    final complete = labelFirst
        ? allConfident && medicines.length == 1
        : allVerified &&
              allConfident &&
              allHaveDoseDetails &&
              medicines.isNotEmpty;
    final averageConfidence =
        medicines.fold<double>(0, (sum, value) => sum + value.confidenceScore) /
        medicines.length;
    final completeness =
        medicines.fold<double>(0, (sum, value) {
          var fields = 0;
          if (value.strength.trim().isNotEmpty) fields++;
          if (value.frequency.trim().isNotEmpty) fields++;
          return sum + fields / 2;
        }) /
        medicines.length;
    final quality =
        averageConfidence +
        (allVerified ? 0.25 : verifiedCount / medicines.length * 0.25) +
        completeness * 0.15 +
        (complete ? 0.2 : 0);

    return _Assessment(
      rawText: rawText,
      medicine: fallback ?? medicines.first,
      medicines: medicines,
      verifiedCount: verifiedCount,
      complete: complete,
      quality: quality,
    );
  }

  OcrScanResult _toResult(
    _Assessment assessment, {
    required OcrResultSource source,
    required bool localWasUnclear,
    bool freeQuotaExceeded = false,
  }) => OcrScanResult(
    rawText: assessment.rawText,
    medicine: assessment.medicine,
    medicines: assessment.medicines,
    isCatalogVerified:
        assessment.medicines.isNotEmpty &&
        assessment.verifiedCount == assessment.medicines.length,
    isComplete: assessment.complete,
    localWasUnclear: localWasUnclear,
    freeQuotaExceeded: freeQuotaExceeded,
    source: source,
  );

  bool _isBetter(_Assessment candidate, _Assessment local) {
    if (candidate.complete && !local.complete) return true;
    if (candidate.medicines.length > local.medicines.length) return true;
    if (candidate.verifiedCount > local.verifiedCount) return true;
    return candidate.quality > local.quality + 0.03;
  }

  /// `true` is Free, `false` is an unlimited paid tier, and null is unknown.
  bool? _tier(String value) {
    switch (value.trim().toLowerCase()) {
      case 'free':
        return true;
      case 'pro':
      case 'medisense pro':
      case 'premium':
      case 'medisense premium':
      case 'guardian':
        return false;
      default:
        return null;
    }
  }

  Future<bool> _hasNetwork() async {
    try {
      final results = await _checkConnectivity();
      return results.any((result) => result != ConnectivityResult.none);
    } on Object {
      return false;
    }
  }

  Future<void> _reserveFreeScan(String userId) async {
    await _withQuotaLock(() async {
      final normalizedUserId = userId.trim();
      if (normalizedUserId.isEmpty) throw const CloudQuotaStorageException();
      final preferences = await _loadPreferences();
      final today = _localDateKey(_now());
      final safeUserId = normalizedUserId.replaceAll(
        RegExp(r'[^A-Za-z0-9_-]'),
        '_',
      );
      final key = 'medisense_cloud_ocr_v1_${safeUserId}_$today';
      final used = preferences.getInt(key) ?? 0;
      if (used >= freeDailyCloudLimit) {
        throw CloudQuotaExceededException(dailyLimit: freeDailyCloudLimit);
      }
      // Reserve before sending; a timed-out request can still have reached
      // Google and incurred a charge.
      if (!await preferences.setInt(key, used + 1)) {
        throw const CloudQuotaStorageException();
      }
    });
  }

  static String _localDateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}'
      '${date.month.toString().padLeft(2, '0')}'
      '${date.day.toString().padLeft(2, '0')}';

  static Future<T> _withQuotaLock<T>(Future<T> Function() action) {
    final previous = _quotaQueue;
    final release = Completer<void>();
    _quotaQueue = release.future;
    return previous
        .then<T>((_) => action())
        .whenComplete(() => release.complete());
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    await _scanQueue;
    try {
      if (_ownsTextRecognizer) await _textRecognizer.close();
    } finally {
      if (_ownsCloudVision) _cloudVision.dispose();
    }
  }
}

class _Assessment {
  const _Assessment({
    required this.rawText,
    required this.medicine,
    required this.medicines,
    required this.verifiedCount,
    required this.complete,
    required this.quality,
  });

  factory _Assessment.empty(String rawText) => _Assessment(
    rawText: rawText,
    medicine: null,
    medicines: const [],
    verifiedCount: 0,
    complete: false,
    quality: 0,
  );

  final String rawText;
  final ParsedMedicine? medicine;
  final List<ParsedMedicine> medicines;
  final int verifiedCount;
  final bool complete;
  final double quality;
}
