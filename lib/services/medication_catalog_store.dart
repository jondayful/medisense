import 'dart:convert';
import 'dart:math' as math;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Shared by the runtime worker and the reproducible seed builder.
const medicationCatalogSchemaVersion = 1;

Future<void> createMedicationCatalog(Database db) async {
  await db.transaction((txn) async {
    await txn.execute('''CREATE TABLE medications (
      id TEXT PRIMARY KEY NOT NULL,
      brand_name TEXT NOT NULL,
      generic_name TEXT NOT NULL,
      dosage_forms TEXT NOT NULL,
      strengths TEXT NOT NULL,
      CHECK (length(brand_name) > 0 OR length(generic_name) > 0)
    )''');
    await txn.execute('''CREATE VIRTUAL TABLE medications_fts
      USING fts5(brand_name, generic_name, prefix='2 3 4',
                 tokenize='unicode61 remove_diacritics 2')''');
    await txn.execute(
      '''CREATE TRIGGER medications_insert AFTER INSERT ON medications
      BEGIN INSERT INTO medications_fts(rowid,brand_name,generic_name)
      VALUES(new.rowid,new.brand_name,new.generic_name); END''',
    );
    await txn.execute(
      '''CREATE TRIGGER medications_delete AFTER DELETE ON medications
      BEGIN DELETE FROM medications_fts WHERE rowid=old.rowid; END''',
    );
    await txn.execute(
      '''CREATE TRIGGER medications_update AFTER UPDATE ON medications
      BEGIN UPDATE medications_fts SET brand_name=new.brand_name,
      generic_name=new.generic_name WHERE rowid=old.rowid; END''',
    );
    await txn.execute('''CREATE TABLE medication_aliases (
      medication_id TEXT NOT NULL REFERENCES medications(id) ON DELETE CASCADE,
      term TEXT NOT NULL, term_length INTEGER NOT NULL,
      display_name TEXT NOT NULL,
      PRIMARY KEY(medication_id,term,display_name))''');
    await txn.execute(
      'CREATE INDEX aliases_length ON medication_aliases(term_length)',
    );
    await txn.execute(
      'CREATE TABLE catalog_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await txn.execute('PRAGMA user_version=$medicationCatalogSchemaVersion');
  });
}

List<String> medicationTokens(String text) => RegExp(
  r'[a-z0-9]+',
).allMatches(text.toLowerCase()).map((m) => m.group(0)!).toList();

String medicationPrefixQuery(String text) =>
    medicationSearchTokens(text).map((token) => '"$token"*').join(' AND ');

/// Package form and strength words add noise to FTS queries and can turn a
/// visible medicine name into an impossible all-token match.
List<String> medicationSearchTokens(String text) {
  const stopwords = {
    'tablet',
    'tablets',
    'tab',
    'tabs',
    'cap',
    'caps',
    'capsule',
    'capsules',
    'syrup',
    'mg',
    'ml',
    'oral',
  };
  return medicationTokens(
    text,
  ).where((token) => !stopwords.contains(token)).toList();
}

/// Adds statements to a single caller-owned transaction batch. Update rather
/// than REPLACE preserves rowids, with FTS triggers keeping both names current.
void addMedicationToBatch(Batch batch, Map<String, Object?> row) {
  final id = row['id'] as String;
  final brand = row['brand_name'] as String;
  final generic = row['generic_name'] as String;
  if (id.isEmpty || (brand.isEmpty && generic.isEmpty)) {
    throw const FormatException('Medication requires an ID and a name');
  }
  batch.rawInsert(
    '''INSERT INTO medications
    (id,brand_name,generic_name,dosage_forms,strengths) VALUES(?,?,?,?,?)
    ON CONFLICT(id) DO UPDATE SET brand_name=excluded.brand_name,
      generic_name=excluded.generic_name,dosage_forms=excluded.dosage_forms,
      strengths=excluded.strengths''',
    [id, brand, generic, row['dosage_forms'], row['strengths']],
  );
  batch.delete('medication_aliases', where: 'medication_id=?', whereArgs: [id]);
  for (final name in {brand, generic}.where((name) => name.isNotEmpty)) {
    final tokens = medicationTokens(name);
    // Full names and words allow an OCR token to suggest a compound name.
    for (final term in {
      tokens.join(' '),
      ...tokens,
    }.where((t) => t.isNotEmpty)) {
      batch.insert('medication_aliases', {
        'medication_id': id,
        'term': term,
        'term_length': term.length,
        'display_name': name,
      });
    }
  }
}

/// Banded Levenshtein, returning maxDistance+1 when outside the bound.
int medicationEditDistance(String a, String b, {int maxDistance = 2}) {
  if ((a.length - b.length).abs() > maxDistance) return maxDistance + 1;
  var previous = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final current = List<int>.filled(b.length + 1, maxDistance + 1);
    current[0] = i;
    var best = current[0];
    for (
      var j = math.max(1, i - maxDistance);
      j <= math.min(b.length, i + maxDistance);
      j++
    ) {
      current[j] = math.min(
        math.min(current[j - 1] + 1, previous[j] + 1),
        previous[j - 1] + (a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1),
      );
      best = math.min(best, current[j]);
    }
    if (best > maxDistance) return maxDistance + 1;
    previous = current;
  }
  return math.min(previous.last, maxDistance + 1);
}

Future<List<String>> lookupMedicationCandidates(Database db, String raw) async {
  if (raw.length > 100) return [];
  final tokens = medicationSearchTokens(raw);
  if (tokens.isEmpty) return [];
  final rows = await db.rawQuery(
    '''SELECT brand_name,generic_name
    FROM medications_fts WHERE medications_fts MATCH ? ORDER BY rank LIMIT 100''',
    [medicationPrefixQuery(raw)],
  );
  final direct = <String, String>{};
  for (final row in rows) {
    for (final value in row.values.cast<String>()) {
      final words = medicationTokens(value);
      if (tokens.every((t) => words.any((word) => word.startsWith(t)))) {
        direct.putIfAbsent(value.toLowerCase(), () => value);
      }
    }
  }
  if (direct.isNotEmpty) return direct.values.take(20).toList();
  final needle = tokens.join(' ');
  // Short, ambiguous OCR fragments should not generate speculative drug names.
  if (needle.length < 5) return [];
  final candidates = <String, (String, int)>{};
  // The length index plus a hard candidate cap keeps the typo pass bounded.
  final fuzzyRows = await db.rawQuery(
    '''SELECT DISTINCT term,display_name FROM medication_aliases
    WHERE term_length BETWEEN ? AND ? ORDER BY term,display_name LIMIT 768''',
    [needle.length - 2, needle.length + 2],
  );
  for (final row in fuzzyRows) {
    final term = row['term'] as String;
    final name = row['display_name'] as String;
    final distance = medicationEditDistance(needle, term, maxDistance: 2);
    final key = name.toLowerCase();
    if (distance <= 2 &&
        (!candidates.containsKey(key) || distance < candidates[key]!.$2)) {
      candidates[key] = (name, distance);
    }
  }
  final ranked = candidates.values.toList()
    ..sort((a, b) {
      final distance = a.$2.compareTo(b.$2);
      return distance != 0
          ? distance
          : a.$1.toLowerCase().compareTo(b.$1.toLowerCase());
    });
  return ranked.take(20).map((entry) => entry.$1).toList();
}

/// Strict envelope validation prevents advancing the sync cursor on bad data.
Map<String, dynamic> decodeNdcPage(String body) {
  final data = jsonDecode(body) as Map<String, dynamic>;
  final rows = data['results'];
  final total = (data['meta'] as Map?)?['results']?['total'];
  if (rows is! List || total is! int || total < 0) {
    throw const FormatException('Malformed openFDA response');
  }
  return data;
}

Map<String, Object?> medicationFromNdc(Map<String, dynamic> row) {
  String field(String key) => (row[key] as String? ?? '').trim();
  final id = field('product_ndc');
  final brand = field('brand_name');
  final generic = field('generic_name');
  if (id.isEmpty || (brand.isEmpty && generic.isEmpty)) {
    throw const FormatException('Missing NDC identifier or medication name');
  }
  final ingredients = row['active_ingredients'] as List? ?? [];
  return {
    'id': 'ndc:$id',
    'brand_name': brand,
    'generic_name': generic,
    'dosage_forms': jsonEncode([
      if (field('dosage_form').isNotEmpty) field('dosage_form'),
    ]),
    'strengths': jsonEncode(
      ingredients
          .map((item) => (item as Map)['strength'] as String? ?? '')
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList(),
    ),
  };
}
