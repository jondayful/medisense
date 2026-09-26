/// Selects a real user-provided name for greetings, ignoring placeholders.
String? resolveGreetingName(Iterable<String?> candidates) {
  for (final candidate in candidates) {
    final name = candidate?.trim();
    if (name == null || name.isEmpty) continue;
    final normalized = name.toLowerCase();
    if (normalized == 'guest' ||
        normalized == 'guest user' ||
        normalized == 'unknown' ||
        normalized == 'null') {
      continue;
    }
    return name;
  }
  return null;
}
