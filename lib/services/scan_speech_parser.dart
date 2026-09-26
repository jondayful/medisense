import 'package:flutter/material.dart';

class ScanSpeechParser {
  static bool isYes(String? text) {
    final normalized = _normalize(text);
    // A partial sound such as "oh" or "ah" can be Vosk noise or TTS echo.
    // Require an explicit, complete answer before advancing the prescription.
    return const {
      'yes',
      'yes please',
      'yeah',
      'yep',
      'yup',
      'oo',
      'opo',
      'opo po',
      'tama',
      'correct',
      'sige',
    }.contains(normalized);
  }

  static bool isNo(String? text) {
    final normalized = _normalize(text);
    return const {
      'no',
      'nope',
      'hindi',
      'hinde',
      'hindi po',
      'mali',
      'wrong',
      'iba',
      'ayaw',
    }.contains(normalized);
  }

  static String? frequencyFromSpeech(String? text) {
    final normalized = _normalize(text);
    if (normalized.isEmpty) return null;

    if (RegExp(
      r'\b(kailangan|pag kailangan|as needed|needed|p r n|prn)\b',
    ).hasMatch(normalized)) {
      return 'As needed';
    }

    // An explicit interval always wins over its number as a daily dose count:
    // "every four hours" means Every 4 hours, while "four times a day"
    // means Every 6 hours.
    if (RegExp(
      r'\b(every|each)\s+(4|four)\s+hours?\b|\b(4|four)\s+hours?\b|\btuwing\s+(apat|4)\s+(na\s+)?oras\b|\b(apat|4)\s+(na\s+)?oras\b',
    ).hasMatch(normalized)) {
      return 'Every 4 hours';
    }
    if (RegExp(
      r'\b(every|each)\s+(6|six)\s+hours?\b|\b(6|six)\s+hours?\b|\btuwing\s+(anim|6)\s+(na\s+)?oras\b|\b(anim|6)\s+(na\s+)?oras\b',
    ).hasMatch(normalized)) {
      return 'Every 6 hours';
    }
    if (RegExp(
      r'\b(every|each)\s+(8|eight)\s+hours?\b|\b(8|eight)\s+hours?\b|\btuwing\s+(walo|walong|8)\s+(na\s+)?oras\b|\b(walo|walong|8)\s+(na\s+)?oras\b',
    ).hasMatch(normalized)) {
      return 'Every 8 hours';
    }
    if (RegExp(
      r'\b(every|each)\s+(12|twelve)\s+hours?\b|\b(12|twelve)\s+hours?\b|\btuwing\s+(labindalawa|labindalawang|12)\s+(na\s+)?oras\b',
    ).hasMatch(normalized)) {
      return 'Every 12 hours';
    }

    // Check the larger counts first. Natural answers such as "dalawang beses
    // sa isang araw" contain both "dalawang" and "isang"; first-match
    // ordering must not downgrade that answer to once daily.
    if (RegExp(r'\b(anim|six|6)\b').hasMatch(normalized)) {
      return 'Every 4 hours';
    }
    if (RegExp(r'\b(apat|four|4)\b').hasMatch(normalized)) {
      return 'Every 6 hours';
    }
    if (RegExp(
      r'\b(tatlo|tatlong|tatlu|three|thrice|tree|tri|3)\b|\b3\s*x\b',
    ).hasMatch(normalized)) {
      return 'Three times a day';
    }
    if (RegExp(
      r'\b(dalawa|dalawang|dalwa|dalwang|two|too|twice|2)\b|\b2\s*x\b',
    ).hasMatch(normalized)) {
      return 'Twice a day';
    }
    if (RegExp(
      r'\b(isa|isang|one|once|wan|1)\b|\b1\s*x\b',
    ).hasMatch(normalized)) {
      return 'Once a day';
    }

    return null;
  }

  /// A spoken time together with the span it occupies in [text], so a caller
  /// can strip it before reading the rest of the sentence.
  ///
  /// This is the single spoken-clock implementation: the guided scan and the
  /// voice navigation dispatcher both resolve times through here, which is what
  /// stops the two copies from disagreeing about "alas siyete ng gabi".
  static ({int start, int end, TimeOfDay time})? timeIn(String? text) {
    final normalized = _normalize(text);
    if (normalized.isEmpty) return null;

    int? hour;
    int minute = 0;
    int start = -1;
    int end = -1;
    final numeric = RegExp(
      r'\b(\d{1,2})(?::(\d{2}))?\s*(a\s*m|am|p\s*m|pm)?\b',
    ).firstMatch(normalized);

    if (numeric != null) {
      hour = int.tryParse(numeric.group(1)!);
      minute = int.tryParse(numeric.group(2) ?? '0') ?? 0;
      start = numeric.start;
      end = numeric.end;
    } else {
      for (final entry in _hourWords.entries) {
        final match = RegExp('\\b${entry.key}\\b').firstMatch(normalized);
        if (match == null) continue;
        hour = entry.value;
        start = match.start;
        end = match.end;
        break;
      }
      // "Ngayon" / "now" means schedule the dose at the current local time.
      // Prefer an explicit spoken hour if the user says both.
      if (hour == null &&
          RegExp(r'\b(ngayon|now|right now)\b').hasMatch(normalized)) {
        final now = TimeOfDay.now();
        return (
          start: RegExp(r'\b(ngayon|now|right now)\b').firstMatch(normalized)!.start,
          end: RegExp(r'\b(ngayon|now|right now)\b').firstMatch(normalized)!.end,
          time: TimeOfDay(hour: now.hour, minute: now.minute),
        );
      }
    }

    if (hour == null || hour < 0 || hour > 23 || minute > 59) return null;

    final explicitMidnight = RegExp(
      r'\b(midnight|hatinggabi|hating gabi|madaling araw)\b',
    ).hasMatch(normalized);
    final numericPeriod = numeric?.group(3)?.replaceAll(' ', '');
    final explicitPm =
        numericPeriod == 'pm' ||
        RegExp(
          r'\b(pm|p m|gabi|hapon|tanghali|noon|afternoon|evening|night)\b',
        ).hasMatch(normalized);
    final explicitAm =
        numericPeriod == 'am' ||
        RegExp(
          r'\b(am|a m|umaga|morning|dawn|madaling araw)\b',
        ).hasMatch(normalized);

    if (explicitMidnight && hour == 12) {
      hour = 0;
    } else if (explicitPm && hour < 12) {
      hour += 12;
    }
    if (explicitAm && hour == 12) {
      hour = 0;
    }

    return (
      start: start < 0 ? 0 : start,
      end: end < 0 ? 0 : end,
      time: TimeOfDay(hour: hour, minute: minute),
    );
  }

  static TimeOfDay? timeFromSpeech(String? text) => timeIn(text)?.time;

  static String _normalize(String? text) {
    if (text == null) return '';
    return text
        .replaceAll(RegExp(r'\[\s*unk\s*\]', caseSensitive: false), ' ')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9:\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static const Map<String, int> _hourWords = {
    'ala una': 1,
    'alas una': 1,
    'isa': 1,
    'one': 1,
    'wan': 1,
    'ala dos': 2,
    'alas dos': 2,
    'dos': 2,
    'dalawa': 2,
    'two': 2,
    'too': 2,
    'ala tres': 3,
    'alas tres': 3,
    'tres': 3,
    'tatlo': 3,
    'three': 3,
    'tree': 3,
    'ala kwatro': 4,
    'alas kwatro': 4,
    'kwatro': 4,
    'quatro': 4,
    'apat': 4,
    'four': 4,
    'for': 4,
    'ala singko': 5,
    'alas singko': 5,
    'singko': 5,
    'cinco': 5,
    'lima': 5,
    'five': 5,
    'ala sais': 6,
    'alas sais': 6,
    'sais': 6,
    'seis': 6,
    'anim': 6,
    'six': 6,
    'ala syete': 7,
    'alas syete': 7,
    'syete': 7,
    'siyete': 7,
    'siete': 7,
    'seben': 7,
    'pito': 7,
    'seven': 7,
    'ala otso': 8,
    'alas otso': 8,
    'a las ocho': 8,
    'otso': 8,
    'otsoh': 8,
    'ocho': 8,
    'otso ocho': 8,
    'walo': 8,
    'eight': 8,
    'ate': 8,
    'ala nuwebe': 9,
    'alas nuwebe': 9,
    'nuwebe': 9,
    'nueve': 9,
    'siyam': 9,
    'nine': 9,
    'ala diyes': 10,
    'alas diyes': 10,
    'diyes': 10,
    'sampu': 10,
    'diez': 10,
    'ten': 10,
    'ala onse': 11,
    'alas onse': 11,
    'onse': 11,
    'once': 11,
    'eleven': 11,
    'ala dose': 12,
    'alas dose': 12,
    'dose': 12,
    'doce': 12,
    'twelve': 12,
  };
}
