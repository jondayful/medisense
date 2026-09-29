import 'dart:io';

/// Summarizes de-identified device trials. It never reads names, prescriptions,
/// spoken transcripts, images, or account identifiers.
void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/summarize_device_trials.dart <ocr.csv> <voice.csv>',
    );
    exitCode = 64;
    return;
  }

  try {
    final ocr = _readRows(
      args[0],
      'trial_id,device,os,name_correct,dosage_correct,expiry_correct,ocr_source',
    );
    final voice = _readRows(
      args[1],
      'trial_id,device,os,language,command_type,task_success,latency_ms',
    );
    _reportOcr(ocr);
    _reportVoice(voice);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 65;
  } on FileSystemException catch (error) {
    stderr.writeln(error.message);
    exitCode = 66;
  }
}

List<Map<String, String>> _readRows(String path, String expectedHeader) {
  final lines = File(path).readAsLinesSync();
  if (lines.isEmpty || lines.first.trim() != expectedHeader) {
    throw FormatException('$path: expected header: $expectedHeader');
  }
  final keys = expectedHeader.split(',');
  final rows = <Map<String, String>>[];
  final seen = <String>{};
  for (var index = 1; index < lines.length; index++) {
    final line = lines[index].trim();
    if (line.isEmpty) continue;
    final values = line.split(',').map((value) => value.trim()).toList();
    if (values.length != keys.length) {
      throw FormatException('$path:${index + 1}: wrong column count');
    }
    final row = Map<String, String>.fromIterables(keys, values);
    for (final key in ['trial_id', 'device', 'os']) {
      if (row[key]!.isEmpty) {
        throw FormatException('$path:${index + 1}: $key is required');
      }
    }
    final unique = '${row['device']}:${row['trial_id']}';
    if (!seen.add(unique)) {
      throw FormatException('$path:${index + 1}: duplicate trial $unique');
    }
    rows.add(row);
  }
  return rows;
}

bool _flag(Map<String, String> row, String key) {
  return switch (row[key]) {
    '1' => true,
    '0' => false,
    _ => throw FormatException(
      '${row['device']}:${row['trial_id']}: $key must be 1 or 0',
    ),
  };
}

String _rate(int correct, int total) => total == 0
    ? 'n/a'
    : '${(100 * correct / total).toStringAsFixed(2)}% ($correct/$total)';

Map<String, List<Map<String, String>>> _byDevice(
  List<Map<String, String>> rows,
) {
  final groups = <String, List<Map<String, String>>>{};
  for (final row in rows) {
    final label = '${row['device']} (${row['os']})';
    groups.putIfAbsent(label, () => []).add(row);
  }
  return groups;
}

void _reportOcr(List<Map<String, String>> rows) {
  stdout.writeln('OCR field correctness');
  for (final entry in _byDevice(rows).entries) {
    final group = entry.value;
    final names = group.where((row) => _flag(row, 'name_correct')).length;
    final dosages = group.where((row) => _flag(row, 'dosage_correct')).length;
    final expiries = group.where((row) => _flag(row, 'expiry_correct')).length;
    final cloud = group.where((row) => row['ocr_source'] == 'cloud').length;
    if (group.any(
      (row) => !{'on_device', 'cloud'}.contains(row['ocr_source']),
    )) {
      throw FormatException(
        '${entry.key}: ocr_source must be on_device or cloud',
      );
    }
    final complete = group
        .where(
          (row) =>
              _flag(row, 'name_correct') &&
              _flag(row, 'dosage_correct') &&
              _flag(row, 'expiry_correct'),
        )
        .length;
    stdout.writeln('  ${entry.key}: ${group.length} scans; cloud route $cloud');
    stdout.writeln('    name ${_rate(names, group.length)}');
    stdout.writeln('    dosage ${_rate(dosages, group.length)}');
    stdout.writeln('    expiry ${_rate(expiries, group.length)}');
    stdout.writeln(
      '    pooled fields ${_rate(names + dosages + expiries, group.length * 3)}',
    );
    stdout.writeln(
      '    all three fields correct ${_rate(complete, group.length)}',
    );
  }
}

void _reportVoice(List<Map<String, String>> rows) {
  stdout.writeln('Voice-command task completion');
  for (final entry in _byDevice(rows).entries) {
    final group = entry.value;
    final successful = group
        .where((row) => _flag(row, 'task_success'))
        .toList();
    var elapsed = 0;
    for (final row in group) {
      if (row['language']!.isEmpty || row['command_type']!.isEmpty) {
        throw FormatException(
          '${entry.key}: language and command_type are required',
        );
      }
      if (!_flag(row, 'task_success')) {
        if (row['latency_ms']!.isNotEmpty) {
          throw FormatException(
            '${entry.key}:${row['trial_id']}: leave failed-attempt latency blank',
          );
        }
        continue;
      }
      final ms = int.tryParse(row['latency_ms']!);
      if (ms == null || ms < 0) {
        throw FormatException(
          '${entry.key}:${row['trial_id']}: successful attempts need a nonnegative latency_ms',
        );
      }
      elapsed += ms;
    }
    final mean = successful.isEmpty
        ? 'n/a'
        : '${(elapsed / successful.length / 1000).toStringAsFixed(2)} s';
    stdout.writeln(
      '  ${entry.key}: ${_rate(successful.length, group.length)}; '
      'mean of successful attempts $mean ($elapsed ms / ${successful.length})',
    );
    final languages = <String, List<Map<String, String>>>{};
    for (final row in group) {
      languages.putIfAbsent(row['language']!, () => []).add(row);
    }
    for (final language in languages.entries) {
      final passed = language.value
          .where((row) => _flag(row, 'task_success'))
          .length;
      stdout.writeln(
        '    language ${language.key}: ${_rate(passed, language.value.length)}',
      );
    }
    final commands = <String, List<Map<String, String>>>{};
    for (final row in group) {
      commands.putIfAbsent(row['command_type']!, () => []).add(row);
    }
    for (final command in commands.entries) {
      final passed = command.value
          .where((row) => _flag(row, 'task_success'))
          .length;
      stdout.writeln(
        '    command ${command.key}: ${_rate(passed, command.value.length)}',
      );
    }
  }
}
