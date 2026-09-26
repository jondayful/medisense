import 'medicine_label_parser.dart';

/// One recognized ML Kit line and its optional platform confidence.
class OcrTextLineConfidence {
  const OcrTextLineConfidence({required this.text, required this.confidence});

  final String text;
  final double? confidence;
}

/// Scores only the OCR lines associated with medicine candidates. Android
/// ML Kit provides line confidence; other platforms may leave it null.
double? medicineOcrConfidence(
  Iterable<OcrTextLineConfidence> recognizedLines,
  Iterable<MedicineLabelResult> candidates,
) {
  final lines = recognizedLines
      .where((line) => line.confidence != null && line.confidence!.isFinite)
      .toList(growable: false);
  final items = candidates.toList(growable: false);
  if (lines.isEmpty || items.isEmpty) return null;

  final candidateScores = <double>[];
  for (final candidate in items) {
    final nameTokens = candidate.name
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((token) => token.length >= 3)
        .toSet();
    final compactStrength = _compact(candidate.dosage);
    final matchingConfidences = <double>[];

    for (final line in lines) {
      final lineTokens = line.text
          .toLowerCase()
          .split(RegExp(r'[^a-z0-9]+'))
          .where((token) => token.isNotEmpty)
          .toSet();
      final compactLine = _compact(line.text);
      final matchesName = nameTokens.any(lineTokens.contains);
      final matchesStrength =
          compactStrength.isNotEmpty && compactLine.contains(compactStrength);
      if (matchesName || matchesStrength) {
        matchingConfidences.add(line.confidence!.clamp(0.0, 1.0).toDouble());
      }
    }

    if (matchingConfidences.isNotEmpty) {
      // A single uncertain medicine should not be hidden by clearer rows.
      candidateScores.add(_minimum(matchingConfidences));
    }
  }

  if (candidateScores.isNotEmpty) return _minimum(candidateScores);

  // OCR cleanup can change every name token. In that case, fall back to the
  // strength-bearing lines; if those are also absent, keep the whole-read
  // minimum so unassociated weak text does not look trustworthy.
  final dosageLines = lines.where(
    (line) => RegExp(
      r'\b\d+(?:[.,]\d+)?\s*(?:mg|ml|mcg|g)\b',
      caseSensitive: false,
    ).hasMatch(line.text),
  );
  return _minimum(
    (dosageLines.isEmpty ? lines : dosageLines)
        .map((line) => line.confidence!.clamp(0.0, 1.0).toDouble())
        .toList(growable: false),
  );
}

double _minimum(List<double> values) =>
    values.reduce((lowest, value) => value < lowest ? value : lowest);

String _compact(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
