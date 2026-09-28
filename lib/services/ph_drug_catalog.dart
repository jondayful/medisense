import 'dart:convert';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

/// A row from the Philippine FDA registered-drug registry.
///
/// This is a product registry, not a prescribing guide. It is used to
/// canonicalize OCR names and display registration metadata; it never supplies
/// a dose or tells a person to take a medicine.
class PhDrugProduct {
  final String registrationNumber;
  final String genericName;
  final String brandName;
  final String dosageStrength;
  final String dosageForm;
  final String classification;
  final String manufacturer;
  final String expiryDate;

  const PhDrugProduct({
    required this.registrationNumber,
    required this.genericName,
    required this.brandName,
    required this.dosageStrength,
    required this.dosageForm,
    required this.classification,
    required this.manufacturer,
    required this.expiryDate,
  });

  factory PhDrugProduct.fromJson(Map<String, dynamic> json) {
    String value(String key) {
      final value = (json[key] as String? ?? '').trim();
      if (RegExp(r'^(none|n/?a|-)$', caseSensitive: false).hasMatch(value)) {
        return '';
      }
      return value;
    }

    return PhDrugProduct(
      registrationNumber: value('r'),
      genericName: value('g'),
      brandName: value('b'),
      dosageStrength: value('s'),
      dosageForm: value('f'),
      classification: value('c'),
      manufacturer: value('m'),
      expiryDate: value('e'),
    );
  }

  String get displayName => brandName.isNotEmpty ? brandName : genericName;
}

class PhDrugCatalogMatch {
  final PhDrugProduct product;
  final double confidence;
  final String matchedAlias;
  final bool matchedBrand;
  final bool exact;

  const PhDrugCatalogMatch({
    required this.product,
    required this.confidence,
    required this.matchedAlias,
    required this.matchedBrand,
    required this.exact,
  });

  /// The name represented by the OCR text. If a brand was printed, preserve
  /// it; otherwise use the generic name rather than inventing a brand.
  String get canonicalName => matchedBrand
      ? product.brandName
      : (product.genericName.isNotEmpty
            ? product.genericName
            : product.brandName);
}

class _AliasRecord {
  final PhDrugProduct product;
  final bool isBrand;

  const _AliasRecord(this.product, this.isBrand);
}

/// Offline Philippine drug catalog backed by the FDA registry export.
///
/// The compressed asset is about 1.3 MB for 34,000+ products. Matching uses
/// exact token-boundary aliases first, then a very conservative one-word OCR
/// correction. In particular, `multivitamin` cannot match `vitamin c` because
/// it is not a token-boundary match.
class PhDrugCatalog {
  PhDrugCatalog._();

  static final PhDrugCatalog instance = PhDrugCatalog._();

  static const _assetPath = 'assets/data/ph_fda_drug_catalog.json.gz';

  Future<void>? _loading;
  bool _loaded = false;
  bool _loadFailed = false;
  List<PhDrugProduct> _products = const [];
  Map<String, List<_AliasRecord>> _aliases = {};
  Map<String, List<_AliasRecord>> _prefixes = {};
  static const _genericSalts = {
    'hydrochloride',
    'hcl',
    'sodium',
    'potassium',
    'calcium',
    'sulfate',
    'sulphate',
    'maleate',
    'tartrate',
    'succinate',
    'phosphate',
  };

  bool get isLoaded => _loaded;
  bool get loadFailed => _loadFailed;
  int get productCount => _products.length;

  Future<void> ensureLoaded() {
    if (_loaded || _loadFailed) return Future<void>.value();
    return _loading ??= _load();
  }

  /// Constant-time full alias lookup used before broader catalog searches.
  /// A phrase must match the complete normalized query to avoid partial-name
  /// substitutions such as matching "vitamin" to "vitamin c".
  PhDrugCatalogMatch? findExactAlias(String text) {
    if (!_loaded) return null;
    final alias = _normalize(text);
    final records = _aliases[alias];
    if (records == null || records.isEmpty) return null;
    final record = records.first;
    return PhDrugCatalogMatch(
      product: record.product,
      confidence: record.isBrand ? .99 : .97,
      matchedAlias: alias,
      matchedBrand: record.isBrand,
      exact: true,
    );
  }

  Future<void> _load() async {
    try {
      final compressed = await rootBundle.load(_assetPath);
      final transferable = TransferableTypedData.fromList([
        compressed.buffer.asUint8List(),
      ]);
      // Decoding alone is not enough: building 34,000+ products and their
      // alias indexes also blocks the UI isolate for a noticeable interval.
      // Isolate.run transfers the completed index back when its worker exits.
      final index = await Isolate.run(() => _decodeAndIndex(transferable));
      _products = index._products;
      _aliases = index._aliases;
      _prefixes = index._prefixes;
      _loaded = true;
    } catch (_) {
      // A missing/corrupt catalog must never block ML Kit OCR or manual entry.
      _loadFailed = true;
    }
  }

  void _addAlias(String value, _AliasRecord record) {
    final alias = _normalize(value);
    if (alias.length < 4) return;
    final records = _aliases.putIfAbsent(alias, () => <_AliasRecord>[]);
    if (!records.any(
      (existing) =>
          existing.product.registrationNumber ==
              record.product.registrationNumber &&
          existing.isBrand == record.isBrand,
    )) {
      records.add(record);
    }

    // Fuzzy matching is intentionally restricted to one-word aliases. This
    // prevents a partial word such as "vitamin" from becoming "Vitamin C".
    final fuzzyAlias = _fuzzyAlias(alias, record.isBrand);
    if (fuzzyAlias != null && fuzzyAlias.length >= 7) {
      _prefixes
          .putIfAbsent(
            _ocrKey(fuzzyAlias).substring(0, 4),
            () => <_AliasRecord>[],
          )
          .add(record);
    }
  }

  String? _fuzzyAlias(String alias, bool isBrand) {
    if (!alias.contains(' ')) return alias;
    final words = alias.split(' ');
    if (!isBrand && words.length == 2 && _genericSalts.contains(words[1])) {
      return words.first;
    }
    return null;
  }

  PhDrugCatalogMatch? findBest(String text) {
    if (!_loaded) return null;
    final normalized = _normalize(text);
    if (normalized.isEmpty) return null;

    final words = normalized.split(' ');
    final matches = <PhDrugCatalogMatch>[];
    final seen = <String>{};

    // Search every contiguous phrase up to eight words using the alias map.
    for (var start = 0; start < words.length; start++) {
      for (
        var length = 1;
        length <= 8 && start + length <= words.length;
        length++
      ) {
        final phrase = words.sublist(start, start + length).join(' ');
        final records = _aliases[phrase];
        if (records == null) continue;
        for (final record in records) {
          final key = '${record.product.registrationNumber}|${record.isBrand}';
          if (!seen.add(key)) continue;
          var confidence = record.isBrand ? 0.98 : 0.95;
          if (_strengthAppearsInText(text, record.product.dosageStrength)) {
            confidence += 0.015;
          }
          matches.add(
            PhDrugCatalogMatch(
              product: record.product,
              confidence: confidence.clamp(0.0, 0.995),
              matchedAlias: phrase,
              matchedBrand: record.isBrand,
              exact: true,
            ),
          );
        }
      }
    }

    if (matches.isEmpty) {
      _addConservativeFuzzyMatches(words, matches);
    }
    if (matches.isEmpty) return null;

    matches.sort((a, b) {
      final confidence = b.confidence.compareTo(a.confidence);
      if (confidence != 0) return confidence;
      return b.matchedAlias.length.compareTo(a.matchedAlias.length);
    });
    return matches.first;
  }

  void _addConservativeFuzzyMatches(
    List<String> words,
    List<PhDrugCatalogMatch> output,
  ) {
    final seen = <String>{};
    for (final word in words) {
      if (word.length < 7) continue;
      final corrected = _ocrKey(word);
      final candidates = _prefixes[corrected.substring(0, 4)];
      if (candidates == null) continue;
      for (final record in candidates) {
        final fullAlias = _normalize(
          record.isBrand
              ? record.product.brandName
              : record.product.genericName,
        );
        final alias = _fuzzyAlias(fullAlias, record.isBrand);
        if (alias == null) continue;
        final distance = _boundedEditDistance(
          corrected,
          _ocrKey(alias),
          word.length > 9 ? 2 : 1,
        );
        final maxDistance = word.length > 9 ? 2 : 1;
        final similarity =
            1 -
            (distance /
                (word.length > alias.length ? word.length : alias.length));
        if (distance > maxDistance ||
            (word.length - alias.length).abs() > 2 ||
            similarity < 0.80) {
          continue;
        }
        final key = '${record.product.registrationNumber}|${record.isBrand}';
        if (!seen.add(key)) continue;
        output.add(
          PhDrugCatalogMatch(
            product: record.product,
            confidence: (0.92 - distance * 0.06).clamp(0.0, 0.92),
            matchedAlias: word,
            matchedBrand: record.isBrand,
            exact: false,
          ),
        );
      }
    }
  }

  bool _strengthAppearsInText(String text, String strength) {
    if (strength.isEmpty) return false;
    final normalizedText = _normalize(text);
    final normalizedStrength = _normalize(strength);
    return normalizedStrength.isNotEmpty &&
        normalizedText.contains(normalizedStrength);
  }

  String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  // Applied only in the indexed fuzzy pass. Exact spelling still wins and
  // short lookalike drug names are not silently corrected.
  String _ocrKey(String value) => value
      .replaceAll('rn', 'm')
      .replaceAll('0', 'o')
      .replaceAll('1', 'l')
      .replaceAll('5', 's');

  int _boundedEditDistance(String a, String b, int maxDistance) {
    var previous = List<int>.generate(b.length + 1, (index) => index);
    for (var i = 1; i <= a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0);
      current[0] = i;
      var rowMin = current[0];
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        final value = [
          previous[j] + 1,
          current[j - 1] + 1,
          previous[j - 1] + cost,
        ].reduce((left, right) => left < right ? left : right);
        current[j] = value;
        if (value < rowMin) rowMin = value;
      }
      if (rowMin > maxDistance) return maxDistance + 1;
      previous = current;
    }
    return previous[b.length];
  }
}

PhDrugCatalog _decodeAndIndex(TransferableTypedData compressed) {
  final bytes = compressed.materialize().asUint8List();
  final decoded = jsonDecode(utf8.decode(GZipDecoder().decodeBytes(bytes)));
  if (decoded is! List) {
    throw const FormatException('Catalog is not a list');
  }
  final index = PhDrugCatalog._();
  final products = <PhDrugProduct>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    final product = PhDrugProduct.fromJson(Map<String, dynamic>.from(item));
    if (product.genericName.isEmpty && product.brandName.isEmpty) continue;
    products.add(product);
    index._addAlias(product.genericName, _AliasRecord(product, false));
    index._addAlias(product.brandName, _AliasRecord(product, true));
  }
  index._products = products;
  return index;
}
