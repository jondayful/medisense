import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;

import 'medication_catalog_store.dart';
import 'medication_database_service.dart';

enum MedicationSyncStatus { updated, notDue, noWifi, cancelled }

class MedicationSyncResult {
  const MedicationSyncResult(this.status, [this.rows = 0]);
  final MedicationSyncStatus status;
  final int rows;
}

class MedicationSyncException implements Exception {
  const MedicationSyncException(this.message);
  final String message;
  @override
  String toString() => 'MedicationSyncException: $message';
}

/// Non-blocking Wi-Fi-only sync while the application process is alive.
/// Call start() once, and dispose before disposing the database. Mobile OSes
/// suspend Dart timers: this does not promise execution while the app is killed.
/// An OS scheduler can invoke syncIfDue from its own initialized Flutter engine.
///
/// openFDA NDC is a snapshot, not a modified-since feed. Each weekly run refreshes
/// up to 1,000 products in a deterministic, rotating window (skip <= 25,000).
/// This bounded catalog expansion is not a full NDC mirror or deletion feed.
class MedicationSyncService {
  MedicationSyncService({
    required this.database,
    http.Client? client,
    Future<bool> Function()? isWifi,
    this._connectivityChanges,
    DateTime Function()? now,
    this.onError,
    this.pagesPerSync = 10,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _isWifi = isWifi ?? _wifiConnected,
       _now = now ?? DateTime.now {
    if (pagesPerSync < 1 ||
        pagesPerSync > 10 ||
        requestTimeout <= Duration.zero) {
      throw ArgumentError('Invalid sync configuration');
    }
  }

  final MedicationDatabaseService database;
  final http.Client _client;
  final bool _ownsClient;
  final Future<bool> Function() _isWifi;
  final Stream<List<ConnectivityResult>>? _connectivityChanges;
  final DateTime Function() _now;
  final void Function(Object, StackTrace)? onError;
  final int pagesPerSync;
  final Duration requestTimeout;
  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Future<MedicationSyncResult>? _active;
  Future<void>? _disposal;
  bool _disposed = false;
  DateTime? _backgroundRetryAfter;
  static const syncInterval = Duration(days: 7);

  static Future<bool> _wifiConnected() async {
    final connections = await Connectivity().checkConnectivity();
    return connections.contains(ConnectivityResult.wifi);
  }

  /// Starts an immediate due check, hourly checks, and Wi-Fi reconnect checks.
  /// Failures preserve the existing catalog and do not update the sync timestamp.
  void start() {
    if (_disposed) throw StateError('Medication sync is disposed');
    if (_timer != null) return;
    _timer = Timer.periodic(
      const Duration(hours: 1),
      (_) => _checkInBackground(),
    );
    _subscription =
        (_connectivityChanges ?? Connectivity().onConnectivityChanged).listen(
          (results) {
            if (results.contains(ConnectivityResult.wifi)) _checkInBackground();
          },
          onError: (Object error, StackTrace stack) =>
              onError?.call(error, stack),
        );
    _checkInBackground();
  }

  void _checkInBackground() {
    if (_disposed ||
        (_backgroundRetryAfter != null &&
            _now().isBefore(_backgroundRetryAfter!))) {
      return;
    }
    unawaited(
      syncIfDue().then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          _backgroundRetryAfter = _now().add(const Duration(minutes: 15));
          onError?.call(error, stack);
        },
      ),
    );
  }

  /// Concurrent callers share one run. Force bypasses age only, never Wi-Fi.
  Future<MedicationSyncResult> syncIfDue({bool force = false}) {
    if (_disposed) {
      return Future.error(StateError('Medication sync is disposed'));
    }
    return _active ??= _sync(force).whenComplete(() => _active = null);
  }

  Future<MedicationSyncResult> _sync(bool force) async {
    final metadata = await database.syncMetadata();
    final previous = metadata['last_sync_timestamp'];
    final last = previous == null ? null : DateTime.tryParse(previous)?.toUtc();
    final now = _now().toUtc();
    // Future timestamps do not indefinitely disable sync after a clock change.
    if (!force &&
        last != null &&
        !last.isAfter(now) &&
        now.difference(last) < syncInterval) {
      return const MedicationSyncResult(MedicationSyncStatus.notDue);
    }
    if (_disposed) {
      return const MedicationSyncResult(MedicationSyncStatus.cancelled);
    }
    if (!await _isWifi()) {
      return const MedicationSyncResult(MedicationSyncStatus.noWifi);
    }
    var offset = int.tryParse(metadata['ndc_next_offset'] ?? '') ?? 0;
    if (offset < 0 || offset > 25000) offset = 0;
    final pages = <String>[];
    var version = '';
    var restarted = false;
    while (pages.length < pagesPerSync) {
      if (_disposed) {
        return const MedicationSyncResult(MedicationSyncStatus.cancelled);
      }
      if (!await _isWifi()) {
        return const MedicationSyncResult(MedicationSyncStatus.noWifi);
      }
      final uri = Uri.https('api.fda.gov', '/drug/ndc.json', {
        'search': 'product_type:"HUMAN PRESCRIPTION DRUG"',
        'sort': 'product_ndc:asc',
        'limit': '100',
        'skip': '$offset',
      });
      final response = await _client.get(uri).timeout(requestTimeout);
      if (response.statusCode == 404 &&
          offset > 0 &&
          pages.isEmpty &&
          !restarted) {
        // A shrinking snapshot can invalidate the stored offset. Only a real
        // API NOT_FOUND envelope permits restart; other 404s remain errors.
        final notFound = await Isolate.run(() {
          final data = jsonDecode(response.body) as Map;
          return (data['error'] as Map?)?['code'] == 'NOT_FOUND';
        });
        if (notFound) {
          offset = 0;
          restarted = true;
          continue;
        }
      }
      if (response.statusCode != 200) {
        throw MedicationSyncException(
          'openFDA returned HTTP ${response.statusCode}; retry later',
        );
      }
      final body = response.body;
      if (body.length > 8 * 1024 * 1024) {
        throw const MedicationSyncException('NDC page exceeds size limit');
      }
      final info = await Isolate.run(() {
        final data = decodeNdcPage(body);
        final meta = data['meta'] as Map;
        return (
          (data['results'] as List).length,
          (meta['results'] as Map)['total'] as int,
          meta['last_updated'] as String? ?? 'unknown',
        );
      });
      if (info.$1 == 0 || info.$1 > 100) {
        throw const MedicationSyncException('Unexpected NDC page size');
      }
      if (version.isNotEmpty && version != info.$3) {
        throw const MedicationSyncException(
          'NDC snapshot changed during sync; retry later',
        );
      }
      version = info.$3;
      pages.add(body);
      offset += info.$1;
      if (offset >= info.$2 || offset > 25000 || info.$1 < 100) {
        offset = 0;
        break;
      }
      // Ten pages per run remains comfortably below public request limits.
      if (pages.length < pagesPerSync) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    if (_disposed) {
      return const MedicationSyncResult(MedicationSyncStatus.cancelled);
    }
    if (!await _isWifi()) {
      return const MedicationSyncResult(MedicationSyncStatus.noWifi);
    }
    final count = await database.applyNdcPages(
      pages,
      syncedAt: _now(),
      nextOffset: offset,
      sourceVersion: version,
      expectedTimestamp: previous,
    );
    return MedicationSyncResult(MedicationSyncStatus.updated, count);
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _timer?.cancel();
    await _subscription?.cancel();
    try {
      await _active;
    } catch (_) {
      /* caller receives the sync failure */
    }
    if (_ownsClient) _client.close();
  }
}
