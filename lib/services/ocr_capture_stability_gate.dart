import 'dart:math' as math;

/// Looks for matching medicine reads over time so brief missed frames and
/// movement inside the camera view do not reset capture readiness.
class OcrCaptureStabilityGate {
  OcrCaptureStabilityGate({
    required this.minSharpness,
    required this.minTextCoverage,
    this.window = const Duration(seconds: 2),
    this.minimumStableReadTime = const Duration(milliseconds: 450),
  });

  final double minSharpness;
  final double minTextCoverage;
  final Duration window;
  final Duration minimumStableReadTime;
  final List<_OcrRead> _reads = [];
  bool shouldPromptHoldSteady = false;

  static final RegExp _strengthPattern = RegExp(
    r'\b\d+(?:[.,]\d+)?\s*(?:mg|mcg|ug|g|ml|iu|units?)\b',
    caseSensitive: false,
  );

  void reset() {
    _reads.clear();
    shouldPromptHoldSteady = false;
  }

  void miss(Duration at) {
    _reads.removeWhere((read) => at - read.at > window);
    shouldPromptHoldSteady = false;
  }

  bool observe({
    required String text,
    required Duration at,
    required double coverage,
    required bool clippedAtEdge,
    required double sharpness,
    String? medicineName,
  }) {
    miss(at);
    if (clippedAtEdge) return false;

    final normalizedText = text
        .replaceAll(String.fromCharCode(0x00b5), 'u')
        .replaceAll(String.fromCharCode(0x03bc), 'u');
    final strengths = _strengthPattern
        .allMatches(normalizedText)
        .map(
          (match) => match
              .group(0)!
              .toLowerCase()
              .replaceAll(RegExp(r'\s+'), '')
              .replaceAll(',', '.')
              .replaceAll('ug', 'mcg'),
        )
        .toSet();
    final key = normalizedText
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();

    _OcrRead? matchingRead;
    for (final read in _reads) {
      final bothHaveStrength =
          strengths.isNotEmpty && read.strengths.isNotEmpty;
      final sameStrength =
          bothHaveStrength && read.strengths.intersection(strengths).isNotEmpty;
      // Strengths are strong evidence when both frames see them. If the
      // camera shake or crop hides a strength in one frame, stable package
      // text can still establish that the label is being held in place.
      final sameMedicine =
          medicineName != null && medicineName == read.medicineName;
      final progressesFromStrength =
          sameStrength && (_isStrengthOnly(key) || _isStrengthOnly(read.key));
      if ((sameStrength || !bothHaveStrength) &&
          (sameMedicine ||
              progressesFromStrength ||
              _similarText(key, read.key))) {
        matchingRead = read;
        break;
      }
    }

    final peakSharpness = _reads.fold<double>(
      sharpness,
      (peak, read) => math.max(peak, read.sharpness).toDouble(),
    );
    _reads.add(_OcrRead(key, strengths, at, sharpness, medicineName));
    if (_reads.length > 4) _reads.removeAt(0);

    final stableLongEnough =
        matchingRead != null && at - matchingRead.at >= minimumStableReadTime;
    shouldPromptHoldSteady = matchingRead != null && !stableLongEnough;

    // Allow for different camera contrast levels, while preferring a frame
    // close to the sharpest recent read before taking the still photograph.
    final hasUsefulText =
        coverage >= minTextCoverage || sharpness >= minSharpness;
    final nearSharpest = peakSharpness <= 0 || sharpness >= peakSharpness * .7;
    return stableLongEnough && hasUsefulText && nearSharpest;
  }

  bool _similarText(String current, String previous) {
    if (current.isEmpty || previous.isEmpty) return false;
    if (current == previous) return true;
    final left = previous.length > 180 ? previous.substring(0, 180) : previous;
    final right = current.length > 180 ? current.substring(0, 180) : current;
    final longest = math.max(left.length, right.length);
    if (longest < 4 || (left.length - right.length).abs() / longest > .3) {
      return false;
    }

    final limit = math.max(2, (longest * .3).round());
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
      if (rowMinimum > limit) return false;
      previousRow = currentRow;
    }
    return previousRow[left.length] <= limit;
  }

  bool _isStrengthOnly(String normalizedText) {
    if (!_strengthPattern.hasMatch(normalizedText)) return false;
    return normalizedText.replaceAll(_strengthPattern, '').trim().isEmpty;
  }
}

class _OcrRead {
  const _OcrRead(
    this.key,
    this.strengths,
    this.at,
    this.sharpness,
    this.medicineName,
  );

  final String key;
  final Set<String> strengths;
  final Duration at;
  final double sharpness;
  final String? medicineName;
}
