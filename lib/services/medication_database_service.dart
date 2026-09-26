import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'medication_catalog_store.dart';
import 'ph_drug_catalog.dart';

class MedicationDatabaseException implements Exception {
  const MedicationDatabaseException(this.message);
  final String message;
  @override
  String toString() => 'MedicationDatabaseException: $message';
}

/// Offline catalog, deliberately separate from the patient's medications table.
/// Use one instance per catalog path. All SQL, JSON parsing, fuzzy comparisons,
/// seed copying and batch construction run on one persistent Dart isolate.
///
/// Uses the sqflite API through its FFI backend with bundled FTS5 SQLite. It
/// does not change the global sqflite factory used by DatabaseHelper.
class MedicationDatabaseService {
  MedicationDatabaseService({
    this._databasePath,
    Future<Uint8List> Function()? loadSeed,
  }) : _loadSeed = loadSeed ?? _bundledSeed;

  static final instance = MedicationDatabaseService();
  final String? _databasePath;
  final Future<Uint8List> Function() _loadSeed;
  Future<void>? _initialization;
  Future<void>? _closing;
  Isolate? _worker;
  SendPort? _commands;
  final ReceivePort _responses = ReceivePort();
  final ReceivePort _errors = ReceivePort();
  final ReceivePort _exit = ReceivePort();
  final Map<int, Completer<Object?>> _pending = {};
  int _nextId = 0;
  bool _disposed = false;
  Object? _failure;

  static Future<Uint8List> _bundledSeed() async {
    final data = await rootBundle.load('assets/initial_meds.db');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<void> initialize() {
    if (_disposed) {
      return Future.error(StateError('Medication database is disposed'));
    }
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    _responses.listen((dynamic message) {
      final response = message as List;
      final completer = _pending.remove(response[0]);
      if (completer == null) return;
      if (response[1] == true) {
        completer.complete(response[2]);
      } else {
        completer.completeError(
          MedicationDatabaseException(response[2] as String),
        );
      }
    });
    _errors.listen(
      (dynamic error) =>
          _fail(MedicationDatabaseException('Worker failed: $error')),
    );
    _exit.listen((_) {
      if (_closing == null || _pending.isNotEmpty) {
        _fail(const MedicationDatabaseException('Database worker exited'));
      }
    });
    try {
      final path =
          _databasePath ??
          p.join(
            (await getApplicationSupportDirectory()).path,
            'medication_catalog.db',
          );
      // Asset loading is asynchronous; copying and validation happen off-UI.
      final seed = await File(path).exists() ? null : await _loadSeed();
      final ready = Completer<Object?>();
      _pending[0] = ready;
      _worker = await Isolate.spawn(
        _catalogWorker,
        (
          _responses.sendPort,
          path,
          seed == null ? null : TransferableTypedData.fromList([seed]),
        ),
        onError: _errors.sendPort,
        onExit: _exit.sendPort,
      );
      _commands = await ready.future as SendPort;
    } catch (error) {
      // If spawning itself failed there is no worker to complete this handshake.
      _pending.remove(0);
      _failure = error;
      rethrow;
    }
  }

  void _fail(Object error) {
    _failure = error;
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
  }

  Future<Object?> _send(String method, Object? args) {
    if (_failure != null) return Future.error(_failure!);
    final id = ++_nextId;
    final reply = Completer<Object?>();
    _pending[id] = reply;
    _commands!.send([id, method, args]);
    return reply.future;
  }

  Future<Object?> _request(String method, [Object? args]) async {
    await initialize();
    if (_disposed) throw StateError('Medication database is disposed');
    return _send(method, args);
  }

  /// Unified offline lookup: O(1) exact alias, then SQLite FTS prefix, then a
  /// distance-two fuzzy fallback. The SQL worker owns both expensive steps.
  Future<List<String>> matchCandidates(String rawWord) async {
    if (rawWord.trim().isEmpty) return const [];
    await PhDrugCatalog.instance.ensureLoaded();
    final exact = PhDrugCatalog.instance.findExactAlias(rawWord);
    if (exact != null) return [exact.canonicalName];
    return (await _request('match', rawWord) as List).cast<String>();
  }

  Future<Map<String, String>> syncMetadata() async =>
      (await _request('metadata') as Map).cast<String, String>();

  /// All pages and version/cursor metadata commit together, or all roll back.
  /// [expectedTimestamp] implements optimistic exclusion across sync callers.
  Future<int> applyNdcPages(
    List<String> pages, {
    required DateTime syncedAt,
    required int nextOffset,
    required String sourceVersion,
    required String? expectedTimestamp,
  }) async =>
      await _request('apply', {
            'pages': pages,
            'timestamp': syncedAt.toUtc().toIso8601String(),
            'offset': nextOffset,
            'version': sourceVersion,
            'expected': expectedTimestamp,
          })
          as int;

  Future<void> dispose() => _closing ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    try {
      if (_initialization != null) {
        try {
          await _initialization;
        } catch (_) {
          // Initialization failure was delivered to its caller. Disposal must
          // still close all ports and release the failed worker.
          return;
        }
        // Worker processes messages serially: close drains earlier operations.
        if (_failure == null) await _send('close', null);
      }
    } finally {
      _worker?.kill(priority: Isolate.immediate);
      _fail(StateError('Medication database is disposed'));
      _responses.close();
      _errors.close();
      _exit.close();
    }
  }
}

Future<void> _validateCatalog(Database db) async {
  final version = await db.getVersion();
  if (version != medicationCatalogSchemaVersion) {
    throw StateError('Unsupported medication catalog schema $version');
  }
  final check = await db.rawQuery('PRAGMA quick_check');
  if (check.single.values.single != 'ok') {
    throw StateError('Catalog integrity check failed');
  }
  await db.rawQuery(
    'SELECT rowid FROM medications_fts WHERE medications_fts MATCH ? LIMIT 1',
    ['"atorvastatin"*'],
  );
  await db.rawQuery(
    'SELECT id,brand_name,generic_name,dosage_forms,strengths FROM medications LIMIT 1',
  );
}

Future<Database> _openCatalog(String path, TransferableTypedData? seed) async {
  sqfliteFfiInit();
  final factory = databaseFactoryFfiNoIsolate;
  await Directory(p.dirname(path)).create(recursive: true);
  // Lock first-install copying across concurrent process starts. Atomic rename
  // ensures a crash cannot leave a half-copied database at the live path.
  final lock = await File('$path.install.lock').open(mode: FileMode.append);
  try {
    await lock.lock(FileLock.exclusive);
    if (!await File(path).exists()) {
      if (seed == null) {
        throw StateError('Initial medication database is missing');
      }
      final temporary = '$path.installing';
      await File(
        temporary,
      ).writeAsBytes(seed.materialize().asUint8List(), flush: true);
      final candidate = await factory.openDatabase(
        temporary,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      try {
        await _validateCatalog(candidate);
      } finally {
        await candidate.close();
      }
      await File(temporary).rename(path);
    }
  } finally {
    await lock.close();
  }
  final db = await factory.openDatabase(
    path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  try {
    await db.execute('PRAGMA foreign_keys=ON');
    await db.execute('PRAGMA busy_timeout=5000');
    await db.rawQuery('PRAGMA journal_mode=WAL');
    await _validateCatalog(db);
    return db;
  } catch (_) {
    await db.close();
    rethrow;
  }
}

Future<Map<String, String>> _metadata(DatabaseExecutor db) async => {
  for (final row in await db.query('catalog_metadata'))
    row['key'] as String: row['value'] as String,
};

Future<int> _applyPages(Database db, Map args) async {
  final pages = (args['pages'] as List).cast<String>();
  if (pages.isEmpty || pages.length > 10 || (args['offset'] as int) < 0) {
    throw ArgumentError('Invalid sync batch');
  }
  final rows = <Map<String, Object?>>[];
  for (final body in pages) {
    final data = decodeNdcPage(body);
    final results = data['results'] as List;
    if (results.isEmpty || results.length > 100) {
      throw const FormatException('Invalid NDC page size');
    }
    rows.addAll(
      results.map((r) => medicationFromNdc(r as Map<String, dynamic>)),
    );
  }
  return db.transaction((txn) async {
    final metadata = await _metadata(txn);
    if (metadata['last_sync_timestamp'] != args['expected']) {
      throw StateError('Another sync completed; retry with fresh metadata');
    }
    final batch = txn.batch();
    for (final row in rows) {
      addMedicationToBatch(batch, row);
    }
    for (final entry in <String, String>{
      'last_sync_timestamp': args['timestamp'] as String,
      'ndc_next_offset': '${args['offset']}',
      'source_version': args['version'] as String,
    }.entries) {
      batch.insert('catalog_metadata', {
        'key': entry.key,
        'value': entry.value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    return rows.length;
  });
}

Future<void> _catalogWorker(
  (SendPort, String, TransferableTypedData?) config,
) async {
  final (responses, path, seed) = config;
  Database? db;
  final commands = ReceivePort();
  try {
    db = await _openCatalog(path, seed);
    responses.send([0, true, commands.sendPort]);
    await for (final dynamic message in commands) {
      final request = message as List;
      final id = request[0] as int;
      try {
        Object? result;
        switch (request[1]) {
          case 'match':
            result = await lookupMedicationCandidates(
              db!,
              request[2] as String,
            );
          case 'metadata':
            result = await _metadata(db!);
          case 'apply':
            result = await _applyPages(db!, request[2] as Map);
          case 'close':
            await db!.close();
            db = null;
            responses.send([id, true, null]);
            return;
          default:
            throw ArgumentError('Unknown catalog operation');
        }
        responses.send([id, true, result]);
      } catch (error) {
        responses.send([id, false, error.toString()]);
      }
    }
  } catch (error) {
    responses.send([0, false, error.toString()]);
  } finally {
    await db?.close();
    commands.close();
  }
}
