/// Five stable, accessible choices for spoken feedback. The displayed speech
/// rate is intentionally separate from the native TTS engine rate: Android's
/// normal FlutterTts rate is 0.5, while people expect 1.0x to mean normal.
class VoiceLevels {
  VoiceLevels._();

  static const List<double> volume = <double>[0.2, 0.4, 0.6, 0.8, 1.0];
  static const List<double> speed = <double>[0.5, 0.75, 1.0, 1.25, 1.5];
  static const List<double> pitch = <double>[0.6, 0.8, 1.0, 1.2, 1.4];

  static int levelFor(double value, List<double> values) {
    var closest = 0;
    var distance = double.infinity;
    for (var index = 0; index < values.length; index++) {
      final candidateDistance = (values[index] - value).abs();
      if (candidateDistance < distance) {
        closest = index;
        distance = candidateDistance;
      }
    }
    return closest + 1;
  }

  static double valueFor(int level, List<double> values) {
    final index = level.clamp(1, values.length).toInt() - 1;
    return values[index];
  }
}
