/// Pure, testable mapping from constrained Vosk text to app actions.
///
/// Keep it independent of Flutter, navigation and TTS so it can be covered by
/// ordinary Dart unit tests and reused by a push-to-talk UI.
///
/// The vocabulary lives in [_rules], one row per intent. Adding a Filipino or
/// English variant is a data change: add the word to the row's set. Matching is
/// [allOf]-based — every group must contribute a word — so no rule can fire on
/// one ambiguous word. A bare "lakasan" is not a command; "lakasan ang boses"
/// is.
library;

import 'scan_speech_parser.dart';

enum VoskVoiceIntent {
  medicationSchedule,
  periodSchedule,
  nextDose,
  markTaken,
  removeMedication,
  rescheduleMedication,
  addMedication,
  snooze,
  adherenceSummary,
  expiringSoon,
  volumeUp,
  volumeDown,
  repeat,
  scan,
  dashboard,
  settings,
  profile,
  guardian,
  userManual,
  accessibility,
  privacy,
  terms,
  whereAmI,
  readScreen,
  help,
}

/// The shared word groups the rules compose. Kept apart from [_rules] so a
/// rule reads as "these words, and also these words" instead of an inline
/// literal.
class _Words {
  const _Words._();

  static const question = {
    'ano',
    'anong',
    'anu',
    'what',
    'when',
    'kailan',
    'kelan',
    'oras',
    'uran',
  };

  static const view = {
    'patingin',
    'tingnan',
    'tingin',
    'open',
    'show',
    'view',
    'see',
    'pakita',
    'ipakita',
    'lista',
    'list',
    'listahan',
    'silip',
  };

  /// "take" on its own is far too common to act on; it only counts beside
  /// another medicine or dose word.
  static const take = {'take'};

  static const medication = {
    'gamot',
    'gamut',
    'medisina',
    'medicine',
    'medicines',
    'meds',
    'medication',
    'iinumin',
    'inumin',
    'umiinom',
    'uminom',
    'inum',
    'inom',
    'iskatla',
    'iskedyul',
    'iskedul',
    'reseta',
    'resetas',
    'prescription',
    'prescriptions',
    'pills',
    'pill',
    'tablet',
    'tablets',
    'capsule',
    'capsules',
    'dose',
    'dosis',
    'doses',
  };

  static const next = {'next', 'susunod', 'kasunod'};

  static const voice = {'boses', 'voice', 'volume', 'lakas', 'tunog', 'sound'};

  /// "malakas" is loud/strong, so it raises the volume. "mahina" and
  /// "marahan" are soft, so they lower it.
  static const raise = {
    'lakasan',
    'lakas',
    'louder',
    'increase',
    'taas',
    'up',
    'malakas',
  };

  static const lower = {
    'hinaan',
    'hina',
    'quieter',
    'decrease',
    'baba',
    'down',
    'mahina',
    'marahan',
  };

  /// One spoken word each: these sets are matched word by word, so a
  /// multi-word entry could never fire. Multi-word forms such as
  /// "madaling araw" and "hating gabi" are matched through their distinctive
  /// word here and resolved by [_periodWords].
  static const period = {
    'umaga',
    'morning',
    'araw',
    'tanghali',
    'hapon',
    'noon',
    'afternoon',
    'gabi',
    'hating',
    'evening',
    'night',
    'bedtime',
  };

  /// How the user says they are doing. "kumusta" is the everyday Filipino
  /// greeting and doubles as a wellbeing question.
  static const wellbeing = {
    'kumusta',
    'kamusta',
    'musta',
    'doing',
    'adherence',
    'compliance',
    'napansin',
    'kayan',
    'tapos',
    'miss',
    'missed',
    'naulit',
    'nalimot',
    'nakita',
    'marka',
  };
}

/// One row of the command table. Order in [_rules] is priority: the first row
/// whose [allOf] groups are all satisfied and whose [noneOf] are all absent
/// wins, so specific destinations are declared before broad ones.
class _Rule {
  const _Rule(
    this.intent, {
    this.route = '',
    this.allOf = const [],
    this.noneOf = const {},
    this.englishReply = '',
    this.filipinoReply = '',
    this.readsPeriod = false,
  });

  final VoskVoiceIntent intent;
  final String route;

  /// Every group must contribute at least one spoken word.
  final List<Set<String>> allOf;

  /// None of these may appear. Keeps a broad word from firing on its own.
  final Set<String> noneOf;

  final String englishReply;
  final String filipinoReply;

  /// Pull Morning/Afternoon/Evening/Night out of the transcript.
  final bool readsPeriod;

  bool matches(Set<String> words) {
    for (final group in allOf) {
      if (!words.any(group.contains)) return false;
    }
    return !words.any(noneOf.contains);
  }
}

class VoskCommand {
  const VoskCommand({
    required this.intent,
    required this.route,
    required this.englishReply,
    required this.filipinoReply,
    this.period,
    this.medicationName,
    this.hour,
    this.minute,
    this.frequency,
    this.medicationNameAlternatives = const [],
  });

  final VoskVoiceIntent intent;
  final String route;
  final String englishReply;
  final String filipinoReply;
  final String? period;
  final String? medicationName;
  final int? hour;
  final int? minute;

  /// "three times a day", "every 8 hours" — for a spoken add.
  final String? frequency;

  /// Other names carried by matching Vosk N-best hypotheses. The provider has
  /// the medication list needed to choose a known name.
  final List<String> medicationNameAlternatives;

  VoskCommand withMedicationNameAlternatives(List<String> names) => VoskCommand(
    intent: intent,
    route: route,
    englishReply: englishReply,
    filipinoReply: filipinoReply,
    period: period,
    medicationName: medicationName,
    hour: hour,
    minute: minute,
    frequency: frequency,
    medicationNameAlternatives: names,
  );

  VoskCommand withMedicationName(String? name) => VoskCommand(
    intent: intent,
    route: route,
    englishReply: englishReply,
    filipinoReply: filipinoReply,
    period: period,
    medicationName: name,
    hour: hour,
    minute: minute,
    frequency: frequency,
    medicationNameAlternatives: medicationNameAlternatives,
  );
}

class VoskCommandDispatcher {
  const VoskCommandDispatcher();

  /// The command vocabulary, most specific first.
  ///
  /// Composition notes that matter:
  ///  * [Words.period] is deliberately "any one period word", so "gamot" alone
  ///    stays a schedule request and only "gamot sa umaga" becomes a period.
  ///  * [Words.voice] gates volume so "up"/"down" can never act alone.
  ///  * [Words.takenVerb] and the add/move/remove verbs are checked in code
  ///    because they also carry the object the command needs.
  static const List<_Rule> _rules = [
    // Reading the current screen out loud. Declared before "basahin" -> scan so
    // "basahin ang screen na ito" is a readout, not a camera request.
    _Rule(
      VoskVoiceIntent.readScreen,
      allOf: [
        {'read', 'basahin', 'sabihin', 'describe', 'ano'},
        {'screen', 'ito', 'this', 'nandito', 'page', 'pahina'},
      ],
    ),
    _Rule(
      VoskVoiceIntent.whereAmI,
      allOf: [
        {'where', 'nasaan', 'saan'},
        {'am', 'ako', 'i', 'ito'},
      ],
    ),
    _Rule(
      VoskVoiceIntent.repeat,
      allOf: [
        {
          'ulit',
          'ulitin',
          'repeat',
          'again',
          'pakiulit',
          'pakisabi',
          'sabihin',
          'say',
          'another',
        },
      ],
    ),
    _Rule(VoskVoiceIntent.volumeUp, allOf: [_Words.voice, _Words.raise]),
    _Rule(
      VoskVoiceIntent.volumeUp,
      allOf: [
        {'louder', 'malakas'},
      ],
    ),
    _Rule(VoskVoiceIntent.volumeDown, allOf: [_Words.voice, _Words.lower]),
    _Rule(
      VoskVoiceIntent.volumeDown,
      allOf: [
        {'quieter', 'softer', 'mahina', 'marahan'},
      ],
    ),

    // A concrete camera request beats the broad word "gamot".
    _Rule(
      VoskVoiceIntent.scan,
      route: '/scan',
      allOf: [
        {
          'scan',
          'camera',
          'kamera',
          'scanner',
          'basahin',
          'iscan',
          'iskanin',
          'kuha',
          'kunan',
          'kuhanan',
          'kumuha',
          'kunin',
          'picture',
          'larawan',
          'photo',
          'litratuhin',
          'litrato',
          'magscan',
          'scanning',
          'etiketa',
          'label',
        },
      ],
      englishReply: 'Opening medicine scan.',
      filipinoReply: 'Binubuksan ang pag-scan ng gamot.',
    ),
    _Rule(
      VoskVoiceIntent.profile,
      route: '/profile',
      allOf: [
        {
          'profile',
          'account',
          'myaccount',
          'details',
          'personal',
          'impormasyon',
        },
      ],
      englishReply: 'Opening your profile.',
      filipinoReply: 'Binubuksan ang iyong profile.',
    ),
    _Rule(
      VoskVoiceIntent.guardian,
      route: '/guardian',
      allOf: [
        {
          'guardian',
          'caregiver',
          'tagapangalaga',
          'family',
          'pamilya',
          'alaga',
          'tagapag',
        },
      ],
      englishReply: 'Opening caregiver settings.',
      filipinoReply: 'Binubuksan ang settings ng tagapangalaga.',
    ),
    _Rule(
      VoskVoiceIntent.userManual,
      route: '/user-manual',
      allOf: [
        {
          'manual',
          'guide',
          'gabay',
          'instructions',
          'tutorial',
          'howto',
          'paano',
          'turuan',
        },
      ],
      englishReply: 'Opening the user manual.',
      filipinoReply: 'Binubuksan ang gabay sa paggamit.',
    ),
    _Rule(
      VoskVoiceIntent.accessibility,
      route: '/settings',
      allOf: [
        {
          'accessibility',
          'accessible',
          'elder',
          'vision',
          'malaki',
          'katutubo',
        },
      ],
      englishReply: 'Opening accessibility settings.',
      filipinoReply: 'Binubuksan ang accessibility settings.',
    ),
    _Rule(
      VoskVoiceIntent.privacy,
      route: '/privacy',
      allOf: [
        {'privacy', 'pribasiya', 'privacy policy'},
      ],
      englishReply: 'Opening the privacy policy.',
      filipinoReply: 'Binubuksan ang patakaran sa privacy.',
    ),
    _Rule(
      VoskVoiceIntent.terms,
      route: '/terms',
      allOf: [
        {'terms', 'legal', 'kasunduan'},
      ],
      englishReply: 'Opening the terms of use.',
      filipinoReply: 'Binubuksan ang mga tuntunin sa paggamit.',
    ),

    // Read-only questions about the user's own day. Before the schedule rules
    // because " kumusta ako" mentions no medicine word but must not fall
    // through to help.
    _Rule(
      VoskVoiceIntent.adherenceSummary,
      allOf: [_Words.wellbeing],
      englishReply: 'Here is how you are doing.',
      filipinoReply: 'Ito ang kalagayan mo.',
    ),
    _Rule(
      VoskVoiceIntent.expiringSoon,
      allOf: [
        {
          'expiring',
          'expiry',
          'expire',
          'expired',
          'naglalaho',
          'mag-e-expire',
          'mageexpire',
          'tinatapos na',
        },
      ],
      englishReply: 'Checking medicines that are running out.',
      filipinoReply: 'Tinitingnan ang mga natatapos na gamot.',
    ),

    _Rule(
      VoskVoiceIntent.nextDose,
      allOf: [_Words.next, _Words.medication],
      englishReply: 'Checking your next medicine.',
      filipinoReply: 'Tinitingnan ang susunod mong gamot.',
    ),
    _Rule(
      VoskVoiceIntent.nextDose,
      allOf: [_Words.take, _Words.question],
      noneOf: {..._Words.medication, ..._Words.period},
      englishReply: 'Checking your next medicine.',
      filipinoReply: 'Tinitingnan ang susunod mong gamot.',
    ),
    _Rule(
      VoskVoiceIntent.periodSchedule,
      route: '/schedule',
      readsPeriod: true,
      allOf: [
        _Words.period,
        {..._Words.medication, ..._Words.take},
      ],
      englishReply: 'Opening your medicines.',
      filipinoReply: 'Binubuksan ang mga gamot mo.',
    ),
    _Rule(
      VoskVoiceIntent.medicationSchedule,
      route: '/schedule',
      allOf: [
        _Words.medication,
        {
          ..._Words.question,
          ..._Words.view,
          ..._Words.take,
          'gamot',
          'gamut',
          'medicine',
          'medication',
          'meds',
          'iinumin',
          'inumin',
          'umiinom',
          'iskedyul',
          'iskedul',
          'reseta',
          'prescription',
          'prescriptions',
          'dose',
          'dosis',
          'doses',
        },
      ],
      englishReply: 'Opening your medication schedule.',
      filipinoReply: 'Binubuksan ang iskedyul ng iyong mga gamot.',
    ),
    _Rule(
      VoskVoiceIntent.dashboard,
      route: '/',
      allOf: [
        {
          'home',
          'dashboard',
          'bahay',
          'tahanan',
          'uwi',
          'uuwi',
          'simula',
          'homepage',
          'homescreen',
          'mainmenu',
          'start',
          'main',
          'unang',
          'back',
          'bumalik',
          'balik',
          'umuwi',
        },
      ],
      englishReply: 'Opening dashboard.',
      filipinoReply: 'Binubuksan ang dashboard.',
    ),
    _Rule(
      VoskVoiceIntent.settings,
      route: '/settings',
      allOf: [
        {
          'settings',
          'setting',
          'seting',
          'ayos',
          'ayusin',
          'pagpipilian',
          'patakaran',
          'preferences',
          'notification',
          'notifications',
          'reminder',
          'reminders',
          'paalala',
        },
      ],
      englishReply: 'Opening settings.',
      filipinoReply: 'Binubuksan ang mga setting.',
    ),
    _Rule(
      VoskVoiceIntent.help,
      route: '/',
      allOf: [
        {'help', 'tulong', 'assist'},
      ],
      englishReply:
          'Say scan this, I took Biogesic, remove Biogesic, move Biogesic to 8 AM, how am I doing, snooze, check your medicine schedule, next dose, settings, or help.',
      filipinoReply:
          'Sabihin ang i-scan ito, nainom ko na ang Biogesic, alisin ang Biogesic, ilipat sa alas otso ang Biogesic, kumusta ako, later, iskedyul ng gamot, susunod na gamot, settings, o tulong.',
    ),
  ];

  /// Exposed so a test can assert the table's own invariant: these sets are
  /// matched word by word, so a multi-word entry could never fire. No
  /// Flutter annotation here — this file stays free of framework imports.
  static List<(String, Set<String>)> get debugWordGroups => [
    ('question', _Words.question),
    ('view', _Words.view),
    ('take', _Words.take),
    ('medication', _Words.medication),
    ('next', _Words.next),
    ('voice', _Words.voice),
    ('raise', _Words.raise),
    ('lower', _Words.lower),
    ('period', _Words.period),
    ('wellbeing', _Words.wellbeing),
  ];

  /// Time-block words. Checked longest-first so "hating gabi" is read as one
  /// phrase rather than as the bare "gabi" inside it.
  static const Map<String, String> _periodWords = {
    'madaling araw': 'Morning',
    'umaga': 'Morning',
    'morning': 'Morning',
    'tanghali': 'Afternoon',
    'hapon': 'Afternoon',
    'noon': 'Afternoon',
    'afternoon': 'Afternoon',
    'hating gabi': 'Evening',
    'gabi': 'Evening',
    'evening': 'Evening',
    'night': 'Night',
    'bedtime': 'Night',
  };

  /// Taken-dose verbs. "umiinom ako" is the ordinary present tense and was
  /// missing before, so the most common Filipino phrasing matched nothing.
  static final List<RegExp> _takenPatterns = [
    RegExp(r'\bmark\s+(.+?)\s+as\s+taken$'),
    RegExp(r'\b(?:i\s+)?(?:have\s+)?(?:already\s+)?(?:taken|took)\s+(.+)$'),
    RegExp(
      r'\b(?:na\s+)?(?:inom|nainom|inuminom|umiinom|uminom)\s+'
      r'(?:ko|na|na ko)?(?:\s+na)?(?:\s+ang)?\s+(.+)$',
    ),
  ];

  static final List<RegExp> _removalPatterns = [
    RegExp(r'\bhindi\s+ko\s+na\s+(?:i)?inumin(?:\s+ang)?\s+(.+)$'),
    RegExp(r'\b(?:remove|delete)\s+(?:the\s+)?(?:medicine\s+)?(.+)$'),
    // Filipino: "alisin ang Biogesic", "tanggalin na".
    RegExp(
      r'\b(?:alisin|alis|tanggalin|bitawan)\s+(?:na\s+)?'
      r'(?:ang\s+|yung\s+|ng\s+)?(?:gamot\s+)?(.+)$',
    ),
    RegExp(
      r'\bi\s+(?:do\s+not|don\s*t|dont)\s+want\s+to\s+take\s+(.+?)\s+anymore$',
    ),
  ];

  /// "later", "not now", "postpone" — no argument needed, the alarm being
  /// snoozed is whichever one is due.
  static final List<RegExp> _snoozePatterns = [
    RegExp(
      r'\b(later|baon|ipagpalit|isuspend|suspend|hindi\s+ngayon|'
      r' hindi\s+pa|not\s+now|remind\s+me\s+later|postpone)\b',
    ),
  ];

  static const _moveWords = {
    'ilipat',
    'lipat',
    'move',
    'reschedule',
    'change',
    'ilagay',
  };

  static const _addWords = {
    'magdagdag',
    'dagdagan',
    'add',
    'ilagay',
    'lagyan',
    'baguhan',
  };

  static const _removeWords = {'remove', 'delete', 'alisin', 'alis', 'bitawan'};

  static const _fillerWords = {
    'ang',
    'yung',
    'ng',
    'na',
    'mo',
    'ko',
    'po',
    'the',
    'my',
    'gamot',
    'medicine',
    'medication',
    'meds',
    'please',
    'nga',
    'ay',
    'ito',
    'iyan',
    'yon',
    'mga',
    'natin',
    'natin po',
  };

  static const _genericNames = {
    'medicine',
    'medication',
    'meds',
    'gamot',
    'gamot na gamot',
    'my medicine',
    'the medicine',
    'medisina',
    'pill',
    'pills',
    'it',
    'that',
    'yon',
    'iyan',
  };

  /// Matches [text] and returns its command, or null when nothing matches.
  VoskCommand? dispatch(String text) {
    final normalized = _normalize(text);
    if (normalized.isEmpty) return null;
    final words = normalized.split(' ');

    // Object-carrying verbs win first: they carry the medicine name or the
    // time, so nothing generic may swallow them.
    final removal = _removalTarget(normalized);
    if (removal != null) {
      return VoskCommand(
        intent: VoskVoiceIntent.removeMedication,
        route: '/schedule',
        medicationName: removal,
        englishReply: 'Do you want to remove $removal from your schedule?',
        filipinoReply: 'Alisin ba ang $removal sa iskedyul mo?',
      );
    }

    final reschedule = _rescheduleTarget(normalized);
    if (reschedule != null) {
      final at = _formatClock(reschedule.hour, reschedule.minute);
      return VoskCommand(
        intent: VoskVoiceIntent.rescheduleMedication,
        route: '/schedule',
        medicationName: reschedule.name,
        hour: reschedule.hour,
        minute: reschedule.minute,
        englishReply: 'Move ${reschedule.name} to $at.',
        filipinoReply: 'Ilipat ang ${reschedule.name} sa $at.',
      );
    }

    final add = _addTarget(normalized);
    if (add != null) {
      return VoskCommand(
        intent: VoskVoiceIntent.addMedication,
        route: '/schedule',
        medicationName: add.name,
        frequency: add.frequency,
        hour: add.hour,
        minute: add.minute,
        englishReply: 'Add ${add.name}.',
        filipinoReply: 'Idagdag ang ${add.name}.',
      );
    }

    final taken = _takenTarget(normalized);
    if (taken != null) {
      return VoskCommand(
        intent: VoskVoiceIntent.markTaken,
        route: '/schedule',
        medicationName: taken,
        englishReply: 'Confirm that you took $taken.',
        filipinoReply: 'Kumpirmahin kung nainom mo na ang $taken.',
      );
    }

    if (_snoozePatterns.any((pattern) => pattern.hasMatch(normalized))) {
      return const VoskCommand(
        intent: VoskVoiceIntent.snooze,
        route: '',
        englishReply: 'I will remind you again in a few minutes.',
        filipinoReply: 'Ipaalala ko sa iyo sa ilang minuto.',
      );
    }

    // "I already took my medicine" with no name: ask which one.
    if (_mentionsTakenVerb(normalized) && _mentionsMedication(words)) {
      return const VoskCommand(
        intent: VoskVoiceIntent.markTaken,
        route: '/schedule',
        medicationName: null,
        englishReply: 'Which medicine did you take?',
        filipinoReply: 'Aling gamot ang ininom mo?',
      );
    }

    for (final rule in _rules) {
      if (!rule.matches(words.toSet())) continue;
      return VoskCommand(
        intent: rule.intent,
        route: rule.route,
        period: rule.readsPeriod ? _periodIn(normalized) : null,
        englishReply: rule.englishReply,
        filipinoReply: rule.filipinoReply,
      );
    }
    return null;
  }

  /// Tries every Vosk alternative and keeps the one that carries the most
  /// usable information. A first guess that matches the verb but garbles the
  /// medicine name loses to a later guess that names it cleanly.
  VoskCommand? dispatchAny(List<String> alternatives) {
    VoskCommand? best;
    final candidates = <VoskCommand>[];
    for (final text in alternatives) {
      final command = dispatch(text);
      if (command == null) continue;
      candidates.add(command);
      if (best == null || _richness(command) > _richness(best)) {
        best = command;
      }
    }
    if (best == null) return null;
    final names = <String>[];
    for (final candidate in candidates) {
      if (candidate.intent != best.intent) continue;
      final name = candidate.medicationName;
      if (name != null && !names.contains(name)) names.add(name);
    }
    return best.withMedicationNameAlternatives(names);
  }

  /// How much a command can actually act on. A named medicine beats a bare
  /// intent; a name plus a time beats a name alone.
  static int _richness(VoskCommand command) {
    var score = 0;
    if (command.medicationName != null) score += 4;
    if (command.frequency != null) score += 2;
    if (command.hour != null) score += 2;
    if (command.period != null) score += 1;
    if (command.route.isNotEmpty) score += 1;
    return score;
  }

  /// "8:05 AM" for a spoken confirmation. The provider re-formats with the
  /// app's own clock helper before it is actually spoken.
  static String _formatClock(int hour, int minute) {
    final display = hour % 12 == 0 ? 12 : hour % 12;
    final suffix = hour < 12 ? 'AM' : 'PM';
    return '$display:${minute.toString().padLeft(2, '0')} $suffix';
  }

  static String? _periodIn(String text) {
    final keys = _periodWords.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final key in keys) {
      if (RegExp('\\b${RegExp.escape(key)}\\b').hasMatch(text)) {
        return _periodWords[key];
      }
    }
    return null;
  }

  static bool _mentionsMedication(List<String> words) =>
      words.any(_Words.medication.contains);

  /// Requires an explicit taken-verb. "inumin ko" on its own is a question
  /// about the schedule, not a claim that a dose happened.
  static bool _mentionsTakenVerb(String text) {
    if (RegExp(
      r'\b(taken|took|nainom|na inom|inuminom|umiinom|uminom|mark)\b',
    ).hasMatch(text)) {
      return true;
    }
    return RegExp(r'\b(?:take|takein|inumin|inom)\b').hasMatch(text) &&
        RegExp(r'\b(now|ngayon|already|na)\b').hasMatch(text);
  }

  /// Vosk emits `[unk]` for unmapped filler/noise. Treat it as whitespace,
  /// not as a failed command: `[unk] ano gamot po` is still actionable.
  static String _normalize(String value) => value
      .replaceAll(RegExp(r'\[\s*unk\s*\]', caseSensitive: false), ' ')
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z0-9:\s]"), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String? _takenTarget(String text) {
    for (final pattern in _takenPatterns) {
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      final name = _cleanMedicationName(match.group(1)!);
      if (name.isNotEmpty && !_isGenericMedicationName(name)) return name;
    }
    return null;
  }

  static String? _removalTarget(String text) {
    for (final pattern in _removalPatterns) {
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      final name = _cleanMedicationName(match.group(1)!);
      if (name.isNotEmpty && !_isGenericMedicationName(name)) return name;
    }
    return null;
  }

  static ({String name, int hour, int minute})? _rescheduleTarget(String text) {
    if (!text.split(' ').any(_moveWords.contains)) return null;
    final time = _timeIn(text);
    if (time == null) return null;
    final withoutTime = _stripPeriodWords(
      text.replaceRange(time.start, time.end, ' '),
    );
    final name = _cleanMedicationName(withoutTime);
    if (name.isEmpty || _isGenericMedicationName(name)) return null;
    return (name: name, hour: time.hour, minute: time.minute);
  }

  /// "alas otso ng umaga" leaves "umaga" behind once the clock span is gone.
  static String _stripPeriodWords(String text) {
    var result = text;
    for (final word in _Words.period) {
      if (word.trim().isEmpty) continue;
      result = result.replaceAll(RegExp('\\b${RegExp.escape(word)}\\b'), ' ');
    }
    return result.replaceAll(RegExp(r'\bsa\b'), ' ');
  }

  static ({String name, String? frequency, int? hour, int? minute})? _addTarget(
    String text,
  ) {
    if (!text.split(' ').any(_addWords.contains)) return null;
    final time = _timeIn(text);
    final withoutTime = time == null
        ? text
        : text.replaceRange(time.start, time.end, ' ');
    final frequency = frequencyFromSpeech(withoutTime);
    final withoutFrequency = frequency == null
        ? withoutTime
        : withoutTime.replaceAll(
            RegExp(
              r'\b(three|twice|once|thrice|daily|every|times?|beses|'
              r'kailangan|pag kailangan|as needed|needed|prn|oras|hours?|'
              r'hour|araw|day|4|6|8|12|four|six|eight|twelve|tatlo|tatlong|'
              r'dalawa|dalawang|isa|isang|apat|anim|walo|labindalawa)\b',
            ),
            ' ',
          );
    final name = _cleanMedicationName(_stripPeriodWords(withoutFrequency));
    if (name.isEmpty || _isGenericMedicationName(name)) return null;
    return (
      name: name,
      frequency: frequency,
      hour: time?.hour,
      minute: time?.minute,
    );
  }

  static ({int start, int end, int hour, int minute})? _timeIn(String text) {
    // Guided scanning and general voice commands share one clock parser so
    // both preserve the exact minute that the user spoke.
    final spoken = ScanSpeechParser.timeIn(text);
    if (spoken == null) return null;
    return (
      start: spoken.start,
      end: spoken.end,
      hour: spoken.time.hour,
      minute: spoken.time.minute,
    );
  }

  /// Delegates to the guided-scan parser so a spoken frequency means the same
  /// thing on both paths.
  static String? frequencyFromSpeech(String text) =>
      ScanSpeechParser.frequencyFromSpeech(text);

  static String _cleanMedicationName(String value) {
    var words = value
        .split(' ')
        .where((word) => word.isNotEmpty && !_fillerWords.contains(word))
        .toList();
    while (words.isNotEmpty && _fillerWords.contains(words.first)) {
      words.removeAt(0);
    }
    while (words.isNotEmpty && _fillerWords.contains(words.last)) {
      words.removeLast();
    }
    // A trailing frequency or time word is not part of the name.
    words = words
        .where(
          (word) =>
              !_moveWords.contains(word) &&
              !_addWords.contains(word) &&
              !_removeWords.contains(word),
        )
        .toList();
    return words.join(' ').trim();
  }

  static bool _isGenericMedicationName(String value) =>
      _genericNames.contains(value) ||
      (value.length < 4 && !value.contains(' '));
}
