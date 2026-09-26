import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter/services.dart';
import '../models/medication.dart';
import '../models/user.dart';
import '../services/password_hasher.dart' as hasher;

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;
  static Future<void>? _catalogImport;

  factory DatabaseHelper() => _instance;

  DatabaseHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'medisense.db');

    return await openDatabase(
      path,
      version: 10,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: _onConfigure,
    );
  }

  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE medications (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL CHECK(length(name) > 0),
        dosage TEXT NOT NULL,
        form TEXT NOT NULL,
        color_hex TEXT NOT NULL,
        expiration_date TEXT,
        frequency TEXT,
        quantity_dispensed INTEGER,
        units_per_dose REAL,
        prescription_start_date TEXT,
        prescription_reviewed INTEGER NOT NULL DEFAULT 0,
        user_id TEXT NOT NULL DEFAULT 'guest',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        is_active INTEGER DEFAULT 1
      )
    ''');
    await db.execute('''
      CREATE TABLE schedules (
        id TEXT PRIMARY KEY,
        medication_id TEXT NOT NULL,
        label TEXT NOT NULL,
        hour INTEGER NOT NULL CHECK(hour >= 0 AND hour <= 23),
        minute INTEGER NOT NULL CHECK(minute >= 0 AND minute <= 59),
        is_active INTEGER NOT NULL DEFAULT 1,
        FOREIGN KEY (medication_id) REFERENCES medications (id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_schedules_active_medication '
      'ON schedules (medication_id, is_active)',
    );

    await db.execute('''
      CREATE TABLE adherence_logs (
        id TEXT PRIMARY KEY,
        medication_id TEXT NOT NULL,
        schedule_id TEXT NOT NULL,
        status TEXT NOT NULL CHECK(status IN ('taken', 'missed', 'pending')),
        timestamp INTEGER NOT NULL,
        notes TEXT,
        FOREIGN KEY (medication_id) REFERENCES medications (id) ON DELETE CASCADE,
        FOREIGN KEY (schedule_id) REFERENCES schedules (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE sync_outbox (
        id TEXT PRIMARY KEY,
        operation TEXT NOT NULL,
        user_id TEXT NOT NULL,
        payload TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        retry_after INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_sync_outbox_retry ON sync_outbox (retry_after, created_at)',
    );

    await db.execute('''
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        email TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL,
        full_name TEXT NOT NULL,
        tier TEXT DEFAULT 'Free',
        role TEXT DEFAULT 'patient',
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE guardian_pairs (
        id TEXT PRIMARY KEY,
        guardian_id TEXT NOT NULL,
        guardian_email TEXT NOT NULL,
        patient_id TEXT NOT NULL,
        patient_email TEXT NOT NULL,
        pairing_code TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        created_at INTEGER NOT NULL
      )
    ''');

    await _createMedicineCatalog(db);

    await db.execute(
      'CREATE INDEX idx_logs_timestamp ON adherence_logs (timestamp)',
    );
    await db.execute(
      'CREATE INDEX idx_logs_med_id ON adherence_logs (medication_id)',
    );
    await db.execute(
      'CREATE INDEX idx_schedules_med_id ON schedules (medication_id)',
    );
    await db.execute(
      'CREATE INDEX idx_medications_user_id ON medications (user_id)',
    );
    await db.execute(
      'CREATE INDEX idx_pairs_guardian ON guardian_pairs (guardian_id)',
    );
    await db.execute(
      'CREATE INDEX idx_pairs_patient ON guardian_pairs (patient_id)',
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS users (
          id TEXT PRIMARY KEY,
          email TEXT UNIQUE NOT NULL,
          password TEXT NOT NULL,
          full_name TEXT NOT NULL,
          tier TEXT DEFAULT 'Free',
          created_at INTEGER NOT NULL
        )
      ''');
    }
    if (oldVersion < 3) {
      await db.execute(
        "ALTER TABLE medications ADD COLUMN user_id TEXT NOT NULL DEFAULT 'guest'",
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_medications_user_id ON medications (user_id)',
      );
    }
    if (oldVersion < 4) {
      try {
        await db.execute(
          "ALTER TABLE users ADD COLUMN role TEXT DEFAULT 'patient'",
        );
      } catch (_) {}

      await db.execute('''
        CREATE TABLE IF NOT EXISTS guardian_pairs (
          id TEXT PRIMARY KEY,
          guardian_id TEXT NOT NULL,
          guardian_email TEXT NOT NULL,
          patient_id TEXT NOT NULL,
          patient_email TEXT NOT NULL,
          pairing_code TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending',
          created_at INTEGER NOT NULL
        )
      ''');

      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_pairs_guardian ON guardian_pairs (guardian_id)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_pairs_patient ON guardian_pairs (patient_id)',
      );
    }
    if (oldVersion < 5) {
      try {
        await db.execute('ALTER TABLE medications ADD COLUMN frequency TEXT');
      } catch (_) {}
    }
    if (oldVersion < 6) {
      for (final statement in [
        'ALTER TABLE medications ADD COLUMN quantity_dispensed INTEGER',
        'ALTER TABLE medications ADD COLUMN units_per_dose REAL',
        'ALTER TABLE medications ADD COLUMN prescription_start_date TEXT',
        'ALTER TABLE medications ADD COLUMN prescription_reviewed INTEGER NOT NULL DEFAULT 0',
      ]) {
        try {
          await db.execute(statement);
        } catch (_) {}
      }
    }
    if (oldVersion < 7) await _createMedicineCatalog(db);
    if (oldVersion < 8) {
      try {
        await db.execute('ALTER TABLE medicines ADD COLUMN aliases TEXT');
      } catch (_) {}
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_medicines_aliases ON medicines(aliases)',
      );
      await _seedGlobalMedicineAliases(db);
    }
    if (oldVersion < 9) {
      await db.execute(
        'ALTER TABLE schedules ADD COLUMN is_active INTEGER NOT NULL DEFAULT 1',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_schedules_active_medication '
        'ON schedules (medication_id, is_active)',
      );
    }
    if (oldVersion < 10) {
      await db.execute('''
        CREATE TABLE sync_outbox (
          id TEXT PRIMARY KEY,
          operation TEXT NOT NULL,
          user_id TEXT NOT NULL,
          payload TEXT NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          retry_after INTEGER NOT NULL DEFAULT 0,
          last_error TEXT,
          created_at INTEGER NOT NULL
        )
      ''');
      await db.execute(
        'CREATE INDEX idx_sync_outbox_retry ON sync_outbox (retry_after, created_at)',
      );
    }
    if (oldVersion < 11) {
      final rows = await db.query(
        'medications',
        columns: ['id', 'expiration_date', 'prescription_start_date'],
        where:
            'expiration_date IS NOT NULL AND prescription_start_date IS NOT NULL',
      );
      for (final row in rows) {
        final expirationDate = DateTime.tryParse(
          row['expiration_date'] as String? ?? '',
        );
        final prescriptionStartDate = DateTime.tryParse(
          row['prescription_start_date'] as String? ?? '',
        );
        if (Medication.isLegacyDefaultExpiration(
          expirationDate: expirationDate,
          prescriptionStartDate: prescriptionStartDate,
        )) {
          await db.update(
            'medications',
            {'expiration_date': null},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
      }
    }
  }

  Future<void> _createMedicineCatalog(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS medicines (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        brand_name TEXT COLLATE NOCASE,
        generic_name TEXT COLLATE NOCASE,
        dosage_form TEXT,
        strength TEXT,
        aliases TEXT,
        country_code TEXT NOT NULL DEFAULT 'GLOBAL'
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_medicines_brand ON medicines(brand_name)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_medicines_generic ON medicines(generic_name)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_medicines_aliases ON medicines(aliases)',
    );
    await _seedGlobalMedicineAliases(db);
  }

  Future<void> _seedGlobalMedicineAliases(Database db) async {
    const rows = [
      ('Betaloc', 'Metoprolol', 'tablet', '100 mg', 'betaloc'),
      ('', 'Dorzolamide', 'generic', '', 'dorzolamidum'),
      ('', 'Cimetidine', 'generic', '50 mg', 'cimetidine'),
      ('Oxprelol', 'Oxprenolol', 'tablet', '50 mg', 'oxprelol'),
    ];
    for (final row in rows) {
      await db.rawInsert(
        '''
        INSERT INTO medicines
          (brand_name, generic_name, dosage_form, strength, aliases, country_code)
        SELECT ?, ?, ?, ?, ?, 'GLOBAL'
        WHERE NOT EXISTS (
          SELECT 1 FROM medicines WHERE brand_name = ? AND generic_name = ?
        )
        ''',
        [row.$1, row.$2, row.$3, row.$4, row.$5, row.$1, row.$2],
      );
    }
  }

  /// Import one or more bundled regional catalogs in one transaction.
  /// Every catalog uses chunked batch commits, so the same fast path applies
  /// to future Philippine, WHO, or other regional CSV files.
  Future<int> importMedicineCatalog(List<String> assetPaths) async {
    final db = await database;
    var imported = 0;
    await db.transaction((txn) async {
      for (final assetPath in assetPaths) {
        final content = await rootBundle.loadString(assetPath);
        final rows = _parseCsv(content);
        if (rows.isEmpty) continue;
        final headers = rows.first.map(_csvHeader).toList();
        final indexes = <String, int>{};
        for (var i = 0; i < headers.length; i++) {
          indexes[headers[i]] = i;
        }
        var batch = txn.batch();
        var batchCount = 0;
        for (final values in rows.skip(1)) {
          String value(List<String> names) {
            for (final name in names) {
              final index = indexes[name];
              if (index != null &&
                  index < values.length &&
                  values[index].trim().isNotEmpty) {
                return values[index].trim();
              }
            }
            return '';
          }

          final brand = value(['brand_name', 'brand', 'trade_name']);
          final generic = value(['generic_name', 'generic', 'inn']);
          if (brand.isEmpty && generic.isEmpty) continue;
          final countryValue = value(['country_code', 'country', 'region']);
          final aliases = value(['aliases', 'alias', 'synonyms']);
          batch.insert('medicines', {
            'brand_name': brand,
            'generic_name': generic,
            'dosage_form': value(['dosage_form', 'form']),
            'strength': value(['strength', 'dosage', 'dosage_strength']),
            'aliases': aliases,
            'country_code': (countryValue.isEmpty ? 'GLOBAL' : countryValue)
                .toUpperCase(),
          });
          imported++;
          batchCount++;
          if (batchCount == 500) {
            await batch.commit(noResult: true);
            batch = txn.batch();
            batchCount = 0;
            // Yield between chunks so large regional catalogs do not monopolize
            // the isolate that owns the database call site.
            await Future<void>.delayed(Duration.zero);
          }
        }
        if (batchCount > 0) await batch.commit(noResult: true);
      }
    });
    return imported;
  }

  /// Loads the bundled catalogs once per installation. The work is awaited by
  /// callers that need database lookup, but callers may safely start it with
  /// `unawaited` during screen startup.
  Future<void> ensureMedicineCatalogImported() {
    return _catalogImport ??= () async {
      final db = await database;
      final count =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM medicines'),
          ) ??
          0;
      if (count > 0) return;
      await importMedicineCatalog(const ['assets/data/us_fda_ndc.csv']);
    }().whenComplete(() => _catalogImport = null);
  }

  Future<List<Map<String, Object?>>> findMedicines(
    String token, {
    String? countryCode,
    int limit = 20,
  }) async {
    final db = await database;
    // Prefix lookups use the catalog indexes and avoid returning unrelated
    // medicines whose names merely contain the OCR token in the middle.
    final pattern = '${token.trim()}%';
    final country = countryCode?.trim().toUpperCase();
    final scoped = country != null && country.isNotEmpty;
    return db.query(
      'medicines',
      where: scoped
          ? '(brand_name LIKE ? OR generic_name LIKE ? OR aliases LIKE ?) AND country_code = ?'
          : 'brand_name LIKE ? OR generic_name LIKE ? OR aliases LIKE ?',
      whereArgs: scoped
          ? [pattern, pattern, pattern, country]
          : [pattern, pattern, pattern],
      orderBy: 'brand_name ASC, generic_name ASC',
      limit: limit,
    );
  }

  List<List<String>> _parseCsv(String input) {
    final output = <List<String>>[];
    final row = <String>[];
    final field = StringBuffer();
    var quoted = false;
    void endField() {
      row.add(field.toString());
      field.clear();
    }

    void endRow() {
      endField();
      if (row.any((v) => v.trim().isNotEmpty)) output.add(List.of(row));
      row.clear();
    }

    for (var i = 0; i < input.length; i++) {
      final char = input[i];
      if (char == '"') {
        if (quoted && i + 1 < input.length && input[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (char == ',' && !quoted) {
        endField();
      } else if ((char == '\n' || char == '\r') && !quoted) {
        if (char == '\r' && i + 1 < input.length && input[i + 1] == '\n') i++;
        endRow();
      } else {
        field.write(char);
      }
    }
    if (field.isNotEmpty || row.isNotEmpty) endRow();
    return output;
  }

  String _csvHeader(String value) => value
      .replaceFirst('\ufeff', '')
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_');

  Future<String> insertMedication(Map<String, dynamic> row) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final values = Map<String, dynamic>.of(row)..['updated_at'] = now;
    await db.transaction((txn) async {
      final id = values['id'] as String;
      final existing = await txn.query(
        'medications',
        columns: ['user_id', 'created_at'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final oldOwner = existing.single['user_id'] as String?;
        final newOwner = values['user_id'] as String?;
        if (oldOwner != null && newOwner != null && oldOwner != newOwner) {
          throw StateError('Medication $id belongs to another user.');
        }
        await txn.update(
          'medications',
          values,
          where: 'id = ?',
          whereArgs: [id],
        );
      } else {
        values['created_at'] = now;
        await txn.insert('medications', values);
      }
    });
    return values['id'] as String;
  }

  /// Saves medication details and schedule rows atomically. Editing retires
  /// removed schedules instead of deleting them, preserving their adherence
  /// rows through the schedules foreign key.
  Future<void> saveMedicationAndSchedules(
    Map<String, dynamic> medication,
    List<Map<String, dynamic>> schedules, {
    required bool replaceSchedules,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final values = Map<String, dynamic>.of(medication)..['updated_at'] = now;
    final medId = values['id'] as String;
    await db.transaction((txn) async {
      final existingMedication = await txn.query(
        'medications',
        columns: ['user_id'],
        where: 'id = ?',
        whereArgs: [medId],
        limit: 1,
      );
      if (existingMedication.isNotEmpty) {
        final oldOwner = existingMedication.single['user_id'] as String?;
        final newOwner = values['user_id'] as String?;
        if (oldOwner != null && newOwner != null && oldOwner != newOwner) {
          throw StateError('Medication $medId belongs to another user.');
        }
        await txn.update(
          'medications',
          values,
          where: 'id = ?',
          whereArgs: [medId],
        );
      } else {
        values['created_at'] = now;
        await txn.insert('medications', values);
      }

      if (replaceSchedules) {
        await txn.update(
          'schedules',
          {'is_active': 0},
          where: 'medication_id = ? AND is_active = 1',
          whereArgs: [medId],
        );
      }
      for (final schedule in schedules) {
        final row = Map<String, dynamic>.of(schedule)..['is_active'] = 1;
        final scheduleId = row['id'] as String;
        final existing = await txn.query(
          'schedules',
          columns: ['id'],
          where: 'id = ? AND medication_id = ?',
          whereArgs: [scheduleId, medId],
          limit: 1,
        );
        if (existing.isEmpty) {
          await txn.insert('schedules', row);
        } else {
          await txn.update(
            'schedules',
            row,
            where: 'id = ? AND medication_id = ?',
            whereArgs: [scheduleId, medId],
          );
        }
      }
    });
  }

  Future<void> insertSchedule(Map<String, dynamic> row) async {
    final db = await database;
    row['is_active'] = row['is_active'] ?? 1;
    final existing = await db.update(
      'schedules',
      row,
      where: 'id = ?',
      whereArgs: [row['id']],
    );
    if (existing == 0) await db.insert('schedules', row);
  }

  Future<List<Map<String, dynamic>>> getAllMedications(String userId) async {
    final db = await database;
    return await db.query(
      'medications',
      where: 'is_active = 1 AND user_id = ?',
      whereArgs: [userId],
      orderBy: 'name ASC',
    );
  }

  Future<List<Map<String, dynamic>>> getSchedulesForMedication(
    String medId,
  ) async {
    final db = await database;
    return await db.query(
      'schedules',
      where: 'medication_id = ? AND is_active = 1',
      whereArgs: [medId],
    );
  }

  Future<List<Map<String, dynamic>>> getAllMedicationsWithSchedules(
    String userId,
  ) async {
    final db = await database;
    return await db.rawQuery(
      '''
      SELECT
        m.id AS med_id,
        m.name AS med_name,
        m.dosage AS med_dosage,
        m.form AS med_form,
        m.color_hex AS med_color_hex,
        m.expiration_date AS med_expiration_date,
        m.frequency AS med_frequency,
        m.quantity_dispensed AS med_quantity_dispensed,
        m.units_per_dose AS med_units_per_dose,
        m.prescription_start_date AS med_prescription_start_date,
        m.prescription_reviewed AS med_prescription_reviewed,
        s.id AS sched_id,
        s.label AS sched_label,
        s.hour AS sched_hour,
        s.minute AS sched_minute
      FROM medications m
      LEFT JOIN schedules s ON s.medication_id = m.id AND s.is_active = 1
      WHERE m.is_active = 1 AND m.user_id = ?
      ORDER BY m.name ASC
    ''',
      [userId],
    );
  }

  Future<List<Map<String, dynamic>>> getTodayLogsForUser(String userId) async {
    final db = await database;
    final now = DateTime.now();
    final startOfDay = DateTime(
      now.year,
      now.month,
      now.day,
    ).millisecondsSinceEpoch;
    return await db.rawQuery(
      '''
      SELECT a.* FROM adherence_logs a
      INNER JOIN medications m ON m.id = a.medication_id
      WHERE m.user_id = ? AND a.timestamp >= ?
    ''',
      [userId, startOfDay],
    );
  }

  Future<void> deleteMedication(String id, String userId) async {
    final db = await database;
    await db.delete(
      'medications',
      where: 'id = ? AND user_id = ?',
      whereArgs: [id, userId],
    );
  }

  Future<void> updateScheduleTime(
    String scheduleId, {
    required String label,
    required int hour,
    required int minute,
  }) async {
    final db = await database;
    await db.update(
      'schedules',
      {'label': label, 'hour': hour, 'minute': minute},
      where: 'id = ?',
      whereArgs: [scheduleId],
    );
  }

  Future<List<Map<String, dynamic>>> getTodayLogsForMedication(
    String medId,
  ) async {
    final db = await database;
    final now = DateTime.now();
    final startOfDay = DateTime(
      now.year,
      now.month,
      now.day,
    ).millisecondsSinceEpoch;
    return await db.query(
      'adherence_logs',
      where: 'medication_id = ? AND timestamp >= ?',
      whereArgs: [medId, startOfDay],
    );
  }

  Future<void> updateAdherenceLog(
    String medId,
    String scheduleId,
    String status, {
    DateTime? recordedAt,
  }) async {
    final db = await database;
    final now = recordedAt ?? DateTime.now();
    final startOfDay = DateTime(
      now.year,
      now.month,
      now.day,
    ).millisecondsSinceEpoch;
    await _writeAdherenceLog(db, medId, scheduleId, status, now, startOfDay);
  }

  Future<void> updateAdherenceLogAndQueue({
    required String medId,
    required String scheduleId,
    required String status,
    required DateTime recordedAt,
    required String outboxId,
    required String userId,
    required Map<String, dynamic> payload,
  }) async {
    final db = await database;
    final now = recordedAt;
    final startOfDay = DateTime(
      now.year,
      now.month,
      now.day,
    ).millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await _writeAdherenceLog(txn, medId, scheduleId, status, now, startOfDay);
      await _writeSyncOperation(
        txn,
        id: outboxId,
        operation: 'adherence',
        userId: userId,
        payload: payload,
      );
    });
  }

  Future<void> _writeAdherenceLog(
    DatabaseExecutor executor,
    String medId,
    String scheduleId,
    String status,
    DateTime now,
    int startOfDay,
  ) async {
    final existing = await executor.query(
      'adherence_logs',
      where:
          'medication_id = ? AND schedule_id = ? AND timestamp >= ? AND timestamp < ?',
      whereArgs: [
        medId,
        scheduleId,
        startOfDay,
        DateTime(now.year, now.month, now.day + 1).millisecondsSinceEpoch,
      ],
    );
    if (existing.isEmpty) {
      await executor.insert('adherence_logs', {
        'id': '${medId}_${scheduleId}_$startOfDay',
        'medication_id': medId,
        'schedule_id': scheduleId,
        'status': status,
        'timestamp': now.millisecondsSinceEpoch,
      });
      return;
    }
    await executor.update(
      'adherence_logs',
      {'status': status, 'timestamp': now.millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [existing.first['id']],
    );
  }

  /// The most recent time [scheduleId] was marked taken, or null if never.
  Future<DateTime?> lastTakenAt(String medId, String scheduleId) async {
    final db = await database;
    final results = await db.query(
      'adherence_logs',
      columns: ['timestamp'],
      where: 'medication_id = ? AND schedule_id = ? AND status = ?',
      whereArgs: [medId, scheduleId, 'taken'],
      orderBy: 'timestamp DESC',
      limit: 1,
    );
    if (results.isEmpty) return null;
    final ts = results.first['timestamp'];
    return ts is int ? DateTime.fromMillisecondsSinceEpoch(ts) : null;
  }

  Future<void> enqueueSyncOperation({
    required String id,
    required String operation,
    required String userId,
    required Map<String, dynamic> payload,
  }) async {
    final db = await database;
    await db.transaction(
      (txn) => _writeSyncOperation(
        txn,
        id: id,
        operation: operation,
        userId: userId,
        payload: payload,
      ),
    );
  }

  Future<void> _writeSyncOperation(
    DatabaseExecutor executor, {
    required String id,
    required String operation,
    required String userId,
    required Map<String, dynamic> payload,
  }) async {
    await executor.insert('sync_outbox', {
      'id': id,
      'operation': operation,
      'user_id': userId,
      'payload': jsonEncode(payload),
      'attempts': 0,
      'retry_after': 0,
      'last_error': null,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> pendingSyncOperations({
    int limit = 100,
  }) async {
    final db = await database;
    final rows = await db.query(
      'sync_outbox',
      where: 'retry_after <= ?',
      whereArgs: [DateTime.now().millisecondsSinceEpoch],
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows
        .map(
          (row) => {
            ...row,
            'payload_json': row['payload'],
            'payload': Map<String, dynamic>.from(
              jsonDecode(row['payload'] as String) as Map,
            ),
          },
        )
        .toList(growable: false);
  }

  Future<void> completeSyncOperation(
    String id, {
    String? expectedPayload,
  }) async {
    final db = await database;
    await db.delete(
      'sync_outbox',
      where: expectedPayload == null ? 'id = ?' : 'id = ? AND payload = ?',
      whereArgs: expectedPayload == null ? [id] : [id, expectedPayload],
    );
  }

  Future<void> retrySyncOperation(
    String id,
    Object error, {
    String? expectedPayload,
  }) async {
    final db = await database;
    final rows = await db.query(
      'sync_outbox',
      columns: ['attempts'],
      where: expectedPayload == null ? 'id = ?' : 'id = ? AND payload = ?',
      whereArgs: expectedPayload == null ? [id] : [id, expectedPayload],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final attempts = (rows.single['attempts'] as int? ?? 0) + 1;
    final seconds = math
        .min(3600, 1 << (attempts < 10 ? attempts : 10))
        .toInt();
    await db.update(
      'sync_outbox',
      {
        'attempts': attempts,
        'retry_after': DateTime.now()
            .add(Duration(seconds: seconds))
            .millisecondsSinceEpoch,
        'last_error': error.toString(),
      },
      where: expectedPayload == null ? 'id = ?' : 'id = ? AND payload = ?',
      whereArgs: expectedPayload == null ? [id] : [id, expectedPayload],
    );
  }

  String hashPassword(String password) => hasher.hashPassword(password);

  Future<void> createUser(Map<String, dynamic> user) async {
    final db = await database;
    user['password'] = hasher.hashPassword(user['password'] as String);
    user['role'] = user['role'] ?? 'patient';
    await db.insert('users', user);
  }

  Future<Map<String, dynamic>?> getUser(String email) async {
    final db = await database;
    final results = await db.query(
      'users',
      where: 'email = ?',
      whereArgs: [email],
    );
    return results.isNotEmpty ? results.first : null;
  }

  Future<List<Map<String, dynamic>>> getUsersByEmailPrefix(
    String emailPrefix,
  ) async {
    final db = await database;
    return await db.query(
      'users',
      where: 'email LIKE ?',
      whereArgs: ['$emailPrefix%'],
    );
  }

  bool verifyPassword(String password, String storedHash) =>
      hasher.verifyPassword(password, storedHash);

  Future<void> updateUserEmail(String oldEmail, String newEmail) async {
    final db = await database;
    await db.update(
      'users',
      {'email': newEmail},
      where: 'email = ?',
      whereArgs: [oldEmail],
    );
  }

  Future<void> updateUserName(String email, String name) async {
    final db = await database;
    await db.update(
      'users',
      {'full_name': name},
      where: 'email = ?',
      whereArgs: [email],
    );
  }

  Future<void> updateUserPassword(String email, String newPassword) async {
    final db = await database;
    await db.update(
      'users',
      {'password': hasher.hashPassword(newPassword)},
      where: 'email = ?',
      whereArgs: [email],
    );
  }

  Future<void> updateUserTier(String email, String newTier) async {
    final db = await database;
    await db.update(
      'users',
      {'tier': newTier},
      where: 'email = ?',
      whereArgs: [email],
    );
  }

  Future<void> insertPairing(PairingRecord record) async {
    final db = await database;
    await db.insert(
      'guardian_pairs',
      record.toDb(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updatePairingStatus(
    String pairingId,
    PairingStatus status,
  ) async {
    final db = await database;
    await db.update(
      'guardian_pairs',
      {'status': status.name},
      where: 'id = ?',
      whereArgs: [pairingId],
    );
  }

  Future<List<PairingRecord>> getPairingsForGuardian(String guardianId) async {
    final db = await database;
    final results = await db.query(
      'guardian_pairs',
      where: 'guardian_id = ?',
      whereArgs: [guardianId],
      orderBy: 'created_at DESC',
    );
    return results.map((r) => PairingRecord.fromDb(r)).toList();
  }

  Future<List<PairingRecord>> getPairingsForPatient(String patientId) async {
    final db = await database;
    final results = await db.query(
      'guardian_pairs',
      where: 'patient_id = ?',
      whereArgs: [patientId],
      orderBy: 'created_at DESC',
    );
    return results.map((r) => PairingRecord.fromDb(r)).toList();
  }

  Future<PairingRecord?> getPairing(String pairingId) async {
    final db = await database;
    final results = await db.query(
      'guardian_pairs',
      where: 'id = ?',
      whereArgs: [pairingId],
    );
    if (results.isEmpty) return null;
    return PairingRecord.fromDb(results.first);
  }

  Future<PairingRecord?> findAcceptedPairing(
    String guardianId,
    String patientId,
  ) async {
    final db = await database;
    final results = await db.query(
      'guardian_pairs',
      where: 'guardian_id = ? AND patient_id = ? AND status = ?',
      whereArgs: [guardianId, patientId, 'accepted'],
    );
    if (results.isEmpty) return null;
    return PairingRecord.fromDb(results.first);
  }
}
