import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/accessibility_mode.dart';
import '../providers/app_state_provider.dart';
import '../theme/app_theme.dart';

class UserManualScreen extends StatefulWidget {
  const UserManualScreen({super.key});

  @override
  State<UserManualScreen> createState() => _UserManualScreenState();
}

class _UserManualScreenState extends State<UserManualScreen> {
  bool? _showFilipino;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final filipino = _showFilipino ?? appState.isFilipino;
    final accessible =
        appState.accessibilityMode.isElder ||
        appState.accessibilityMode.isVisionLoss;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final primary = AppTheme.primaryTextColor(context);
    final secondary = AppTheme.secondaryTextColor(context);
    final accent = accessible
        ? (dark ? AppTheme.elderDarkAction : AppTheme.elderAction)
        : (dark ? AppTheme.darkAccentGreen : AppTheme.primaryDark);

    return Scaffold(
      appBar: AppBar(
        title: Text(filipino ? 'Gabay sa Paggamit' : 'User Manual'),
        toolbarHeight: accessible ? 88 : null,
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            accessible ? 20 : 18,
            16,
            accessible ? 20 : 18,
            40,
          ),
          children: [
            _ManualIntro(
              filipino: filipino,
              accessible: accessible,
              accent: accent,
              primary: primary,
              secondary: secondary,
            ),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('English'),
                  icon: Icon(Icons.translate_rounded),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('Filipino'),
                  icon: Icon(Icons.language_rounded),
                ),
              ],
              selected: {filipino},
              onSelectionChanged: (selection) {
                setState(() => _showFilipino = selection.first);
              },
              style: ButtonStyle(
                minimumSize: WidgetStatePropertyAll(
                  Size.fromHeight(accessible ? 58 : 48),
                ),
              ),
            ),
            const SizedBox(height: 26),
            _QuickStart(
              filipino: filipino,
              accessible: accessible,
              accent: accent,
              primary: primary,
              secondary: secondary,
            ),
            const SizedBox(height: 26),
            Text(
              filipino ? 'Mga paksa' : 'Guide by task',
              style: AppTheme.textStyle(
                fontSize: accessible ? 25 : 20,
                fontWeight: FontWeight.w800,
                color: primary,
              ),
            ),
            const SizedBox(height: 12),
            for (var index = 0; index < _chapters.length; index++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _ManualChapterCard(
                  chapter: _chapters[index],
                  filipino: filipino,
                  accessible: accessible,
                  accent:
                      AppTheme.medicationColors[index %
                          AppTheme.medicationColors.length],
                  primary: primary,
                  secondary: secondary,
                ),
              ),
            const SizedBox(height: 12),
            _SafetyNote(
              filipino: filipino,
              accessible: accessible,
              primary: primary,
              secondary: secondary,
            ),
          ],
        ),
      ),
    );
  }
}

class _ManualIntro extends StatelessWidget {
  const _ManualIntro({
    required this.filipino,
    required this.accessible,
    required this.accent,
    required this.primary,
    required this.secondary,
  });

  final bool filipino;
  final bool accessible;
  final Color accent;
  final Color primary;
  final Color secondary;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Semantics(
      header: true,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              accent.withValues(alpha: dark ? 0.28 : 0.16),
              AppTheme.foil.withValues(alpha: dark ? 0.18 : 0.10),
            ],
          ),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: accent.withValues(alpha: 0.38)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontal = constraints.maxWidth >= 520;
            final copy = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceColor(
                      context,
                    ).withValues(alpha: 0.88),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.offline_bolt_rounded, size: 15, color: accent),
                      const SizedBox(width: 6),
                      Text(
                        filipino
                            ? 'OFFLINE • DALAWANG WIKA'
                            : 'OFFLINE • BILINGUAL',
                        style: AppTheme.microLabel(
                          color: primary,
                          fontSize: accessible ? 16 : 10,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  filipino
                      ? 'Kasama mo sa bawat gamot'
                      : 'Your medicine, made simpler',
                  style: AppTheme.textStyle(
                    fontSize: accessible ? 28 : 24,
                    height: 1.12,
                    fontWeight: FontWeight.w800,
                    color: primary,
                  ),
                ),
                const SizedBox(height: 9),
                Text(
                  filipino
                      ? 'Sundan ang mga larawan para mag-scan, magtakda ng oras, at gumamit ng boses.'
                      : 'Follow the visual path to scan, schedule, and use voice guidance.',
                  style: AppTheme.textStyle(
                    fontSize: accessible ? 17 : 15,
                    height: 1.45,
                    color: secondary,
                  ),
                ),
              ],
            );

            return Padding(
              padding: EdgeInsets.all(accessible ? 22 : 18),
              child: horizontal
                  ? Row(
                      children: [
                        Expanded(child: copy),
                        const SizedBox(width: 18),
                        _CareOrbitIllustration(accent: accent),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        copy,
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerRight,
                          child: _CareOrbitIllustration(accent: accent),
                        ),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }
}

class _CareOrbitIllustration extends StatelessWidget {
  const _CareOrbitIllustration({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Scan, schedule, and voice guidance illustration',
      image: true,
      child: SizedBox(
        width: 210,
        height: 132,
        child: CustomPaint(
          painter: _CarePathPainter(accent.withValues(alpha: 0.42)),
          child: Stack(
            children: [
              Positioned(
                left: 72,
                top: 28,
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.28),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.medication_rounded,
                    color: Colors.white,
                    size: 38,
                  ),
                ),
              ),
              _OrbitNode(
                left: 0,
                top: 9,
                icon: Icons.document_scanner_rounded,
                color: AppTheme.medicationColors[0],
              ),
              _OrbitNode(
                left: 158,
                top: 0,
                icon: Icons.schedule_rounded,
                color: AppTheme.medicationColors[3],
              ),
              _OrbitNode(
                left: 158,
                top: 82,
                icon: Icons.mic_rounded,
                color: AppTheme.medicationColors[4],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrbitNode extends StatelessWidget {
  const _OrbitNode({
    required this.left,
    required this.top,
    required this.icon,
    required this.color,
  });

  final double left;
  final double top;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: left,
      top: top,
      child: Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          color: AppTheme.surfaceColor(context),
          shape: BoxShape.circle,
          border: Border.all(color: color.withValues(alpha: 0.42)),
        ),
        child: Icon(icon, color: color, size: 25),
      ),
    );
  }
}

class _CarePathPainter extends CustomPainter {
  const _CarePathPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final center = Offset(size.width * 0.52, size.height * 0.5);
    canvas.drawLine(center, const Offset(25, 34), paint);
    canvas.drawLine(center, Offset(size.width - 27, 25), paint);
    canvas.drawLine(center, Offset(size.width - 27, size.height - 25), paint);
  }

  @override
  bool shouldRepaint(covariant _CarePathPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _QuickStart extends StatelessWidget {
  const _QuickStart({
    required this.filipino,
    required this.accessible,
    required this.accent,
    required this.primary,
    required this.secondary,
  });

  final bool filipino;
  final bool accessible;
  final Color accent;
  final Color primary;
  final Color secondary;

  @override
  Widget build(BuildContext context) {
    final steps = filipino
        ? const [
            (
              '1',
              'I-scan',
              'Itapat nang malinaw ang pangalan at lakas ng gamot.',
              Icons.document_scanner_rounded,
            ),
            (
              '2',
              'Kumpirmahin',
              'Suriin ang pangalan, dosage, at expiration date.',
              Icons.fact_check_rounded,
            ),
            (
              '3',
              'Itakda',
              'Piliin kung ilang beses at anong oras iinumin.',
              Icons.event_available_rounded,
            ),
            (
              '4',
              'Subaybayan',
              'Pindutin ang Mark as Taken pagkatapos uminom.',
              Icons.task_alt_rounded,
            ),
          ]
        : const [
            (
              '1',
              'Scan',
              'Clearly frame the medicine name and strength.',
              Icons.document_scanner_rounded,
            ),
            (
              '2',
              'Confirm',
              'Check the name, dosage, and expiration date.',
              Icons.fact_check_rounded,
            ),
            (
              '3',
              'Schedule',
              'Choose how often and what time to take it.',
              Icons.event_available_rounded,
            ),
            (
              '4',
              'Track',
              'Tap Mark as Taken after taking your dose.',
              Icons.task_alt_rounded,
            ),
          ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: accessible ? 30 : 24,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              filipino ? 'Mabilis na pagsisimula' : 'Quick start',
              style: AppTheme.textStyle(
                fontSize: accessible ? 25 : 20,
                fontWeight: FontWeight.w800,
                color: primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        Padding(
          padding: const EdgeInsets.only(left: 18),
          child: Text(
            filipino
                ? 'Apat na hakbang mula label hanggang dosis.'
                : 'Four steps from label to dose.',
            style: AppTheme.textStyle(
              fontSize: accessible ? 16 : 13,
              color: secondary,
            ),
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            // Instructional copy must remain complete. Phone and narrow-tablet
            // layouts use one column rather than squeezing text into fixed
            // two-column cards and replacing the final words with an ellipsis.
            final oneColumn = constraints.maxWidth < 600;
            final cardWidth = oneColumn
                ? constraints.maxWidth
                : (constraints.maxWidth - 12) / 2;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (var index = 0; index < steps.length; index++)
                  SizedBox(
                    width: cardWidth,
                    child: _QuickStep(
                      number: steps[index].$1,
                      title: steps[index].$2,
                      detail: steps[index].$3,
                      icon: steps[index].$4,
                      accessible: accessible,
                      accent: AppTheme.medicationColors[index],
                      primary: primary,
                      secondary: secondary,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _QuickStep extends StatelessWidget {
  const _QuickStep({
    required this.number,
    required this.title,
    required this.detail,
    required this.icon,
    required this.accessible,
    required this.accent,
    required this.primary,
    required this.secondary,
  });

  final String number;
  final String title;
  final String detail;
  final IconData icon;
  final bool accessible;
  final Color accent;
  final Color primary;
  final Color secondary;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(accessible ? 17 : 15),
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                width: accessible ? 54 : 48,
                height: accessible ? 54 : 48,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(icon, color: accent, size: accessible ? 30 : 26),
              ),
              Container(
                width: accessible ? 34 : 30,
                height: accessible ? 34 : 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  number,
                  style: AppTheme.textStyle(
                    color: Colors.white,
                    fontSize: accessible ? 16 : 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: accessible ? 18 : 14),
          Text(
            title,
            style: AppTheme.textStyle(
              color: primary,
              fontSize: accessible ? 18 : 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            style: AppTheme.textStyle(
              color: secondary,
              fontSize: accessible ? 16 : 12,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _ManualChapterCard extends StatelessWidget {
  const _ManualChapterCard({
    required this.chapter,
    required this.filipino,
    required this.accessible,
    required this.accent,
    required this.primary,
    required this.secondary,
  });

  final _ManualChapter chapter;
  final bool filipino;
  final bool accessible;
  final Color accent;
  final Color primary;
  final Color secondary;

  @override
  Widget build(BuildContext context) {
    final title = filipino ? chapter.titleFilipino : chapter.titleEnglish;
    final summary = filipino ? chapter.summaryFilipino : chapter.summaryEnglish;
    final items = filipino ? chapter.itemsFilipino : chapter.itemsEnglish;
    final cues = _cuesForChapter(chapter.icon, filipino);

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: accent.withValues(alpha: 0.24)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          backgroundColor: accent.withValues(alpha: 0.035),
          collapsedBackgroundColor: AppTheme.surfaceColor(context),
          iconColor: accent,
          collapsedIconColor: accent,
          tilePadding: EdgeInsets.symmetric(
            horizontal: accessible ? 20 : 16,
            vertical: accessible ? 10 : 6,
          ),
          childrenPadding: EdgeInsets.fromLTRB(
            accessible ? 22 : 18,
            0,
            accessible ? 22 : 18,
            accessible ? 22 : 18,
          ),
          leading: Container(
            width: accessible ? 58 : 52,
            height: accessible ? 58 : 52,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(17),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(chapter.icon, color: accent, size: accessible ? 31 : 27),
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
          ),
          title: Text(
            title,
            maxLines: accessible ? null : 2,
            softWrap: true,
            style: AppTheme.textStyle(
              fontSize: accessible ? 20 : 17,
              fontWeight: FontWeight.w800,
              color: primary,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  summary,
                  style: AppTheme.textStyle(
                    fontSize: accessible ? 16 : 14,
                    color: secondary,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 9),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final cue in cues)
                      _GuideCue(
                        label: cue,
                        color: accent,
                        accessible: accessible,
                      ),
                  ],
                ),
              ],
            ),
          ),
          children: [
            Divider(color: accent.withValues(alpha: 0.22)),
            const SizedBox(height: 6),
            for (var index = 0; index < items.length; index++)
              Padding(
                padding: const EdgeInsets.only(bottom: 13),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: accessible ? 30 : 26,
                      height: accessible ? 30 : 26,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.13),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.check_rounded,
                        color: accent,
                        size: accessible ? 18 : 16,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        items[index],
                        style: AppTheme.textStyle(
                          fontSize: accessible ? 17 : 15,
                          height: 1.5,
                          color: primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<String> _cuesForChapter(IconData icon, bool filipino) {
    if (icon == Icons.home_rounded) {
      return filipino ? const ['SUSUNOD', 'NAINOM'] : const ['NEXT', 'TAKEN'];
    }
    if (icon == Icons.document_scanner_outlined) {
      return filipino
          ? const ['PANGALAN', 'LAKAS', 'EXP']
          : const ['NAME', 'STRENGTH', 'EXP'];
    }
    if (icon == Icons.calendar_month_rounded) {
      return const ['AM', 'PM', 'REMINDERS'];
    }
    if (icon == Icons.mic_rounded) {
      return const ['SCHEDULE', 'SCAN', 'LAKASAN'];
    }
    if (icon == Icons.accessibility_new_rounded) {
      return const ['ELDER', 'VISION', 'LANGUAGE'];
    }
    return const ['MIC', 'CAMERA', 'ALERTS'];
  }
}

class _GuideCue extends StatelessWidget {
  const _GuideCue({
    required this.label,
    required this.color,
    required this.accessible,
  });

  final String label;
  final Color color;
  final bool accessible;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: AppTheme.microLabel(
          color: color,
          fontSize: accessible ? 16 : 12,
          letterSpacing: accessible ? 0.5 : 0.7,
        ),
      ),
    );
  }
}

class _SafetyNote extends StatelessWidget {
  const _SafetyNote({
    required this.filipino,
    required this.accessible,
    required this.primary,
    required this.secondary,
  });

  final bool filipino;
  final bool accessible;
  final Color primary;
  final Color secondary;

  @override
  Widget build(BuildContext context) {
    final warning = Theme.of(context).brightness == Brightness.dark
        ? AppTheme.darkWarning
        : AppTheme.warning;
    return Container(
      padding: EdgeInsets.all(accessible ? 20 : 17),
      decoration: BoxDecoration(
        color: warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: warning.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: accessible ? 60 : 52,
            height: accessible ? 60 : 52,
            decoration: BoxDecoration(
              color: warning.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(17),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  Icons.health_and_safety_rounded,
                  color: warning,
                  size: accessible ? 35 : 31,
                ),
                Positioned(
                  right: 5,
                  bottom: 5,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceColor(context),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.medication_rounded,
                      color: warning,
                      size: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  filipino ? 'Paalalang pangkaligtasan' : 'Safety reminder',
                  style: AppTheme.textStyle(
                    fontSize: accessible ? 19 : 16,
                    fontWeight: FontWeight.w800,
                    color: primary,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  filipino
                      ? 'Palaging ihambing ang pangalan, dosage, oras, at expiration date sa orihinal na label o reseta. Kumonsulta sa doktor o pharmacist kapag may hindi malinaw.'
                      : 'Always compare the medicine name, dosage, time, and expiration date with the original label or prescription. Ask a doctor or pharmacist when anything is unclear.',
                  style: AppTheme.textStyle(
                    fontSize: accessible ? 16 : 14,
                    height: 1.45,
                    color: secondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ManualChapter {
  const _ManualChapter({
    required this.icon,
    required this.titleEnglish,
    required this.titleFilipino,
    required this.summaryEnglish,
    required this.summaryFilipino,
    required this.itemsEnglish,
    required this.itemsFilipino,
  });

  final IconData icon;
  final String titleEnglish;
  final String titleFilipino;
  final String summaryEnglish;
  final String summaryFilipino;
  final List<String> itemsEnglish;
  final List<String> itemsFilipino;
}

const _chapters = <_ManualChapter>[
  _ManualChapter(
    icon: Icons.home_rounded,
    titleEnglish: 'Home and today’s doses',
    titleFilipino: 'Home at mga gamot ngayong araw',
    summaryEnglish: 'See what is due and record a taken dose.',
    summaryFilipino: 'Tingnan ang oras ng gamot at itala kapag nainom na.',
    itemsEnglish: [
      'The large card shows the next dose that needs attention.',
      'Tap Take Now or Mark as Taken only after the medicine has been taken.',
      'Use the time filters to view morning, afternoon, evening, or night doses.',
    ],
    itemsFilipino: [
      'Makikita sa malaking card ang susunod na gamot na kailangan mong asikasuhin.',
      'Pindutin lamang ang Take Now o Mark as Taken pagkatapos inumin ang gamot.',
      'Gamitin ang mga time filter para makita ang gamot sa umaga, hapon, gabi, o oras ng pagtulog.',
    ],
  ),
  _ManualChapter(
    icon: Icons.document_scanner_outlined,
    titleEnglish: 'Scan a medicine label',
    titleFilipino: 'Mag-scan ng label ng gamot',
    summaryEnglish: 'Capture the name, strength, and expiration date.',
    summaryFilipino: 'Basahin ang pangalan, lakas, at expiration date.',
    itemsEnglish: [
      'Place the package on a steady, well-lit surface and keep the label inside the guide.',
      'Check every detected detail before confirming. Edit anything that does not match the package.',
      'A detected expired medicine is blocked. A month-and-year expiry remains valid through the final day of that month.',
      'The expiration date is saved in the schedule. A warning appears in the schedule during the 30 days before expiry, and an expired scan is announced aloud.',
      'After confirmation, choose frequency and time before saving.',
    ],
    itemsFilipino: [
      'Ipatong ang pakete sa maliwanag at hindi gumagalaw na lugar, at ilagay ang label sa loob ng guide.',
      'Suriin ang lahat ng nabasang detalye bago kumpirmahin. Itama ang hindi tugma sa pakete.',
      'Hindi maaaring idagdag ang gamot na expired na. Ang buwan at taon na expiry ay valid hanggang huling araw ng buwan.',
      'Nase-save ang expiration date sa iskedyul. May babala sa iskedyul sa loob ng 30 araw bago ito mag-expire, at binibigkas ang babala kapag expired na ang na-scan.',
      'Pagkatapos kumpirmahin, piliin ang dalas at oras bago i-save.',
    ],
  ),
  _ManualChapter(
    icon: Icons.calendar_month_rounded,
    titleEnglish: 'Schedule and reminders',
    titleFilipino: 'Iskedyul at mga paalala',
    summaryEnglish: 'Review doses and set ringing medication alarms.',
    summaryFilipino: 'Suriin ang mga dose at magtakda ng alarm sa gamot.',
    itemsEnglish: [
      'Open Schedule to see every saved medicine grouped by time of day.',
      'Open a medicine to review or change its dosage, frequency, and times.',
      'Keep Medication alarms enabled in Settings. At dose time, the phone plays its alarm sound and repeats vibration until you stop or snooze it.',
      'Set the phone’s Alarm volume to a level you can hear. Android needs Alarms & reminders access and notification permission for the alarm controls.',
    ],
    itemsFilipino: [
      'Buksan ang Schedule para makita ang lahat ng gamot ayon sa oras ng araw.',
      'Buksan ang isang gamot para suriin o baguhin ang dosage, dalas, at oras.',
      'Panatilihing naka-on ang Medication alarms sa Settings. Sa oras ng dose, tutunog ang alarm ng telepono at uulit ang vibration hanggang ihinto o i-snooze mo ito.',
      'Itakda ang Alarm volume ng telepono sa lakas na maririnig mo. Kailangan ng Android ang Alarms & reminders access at notification permission para sa mga control ng alarm.',
    ],
  ),
  _ManualChapter(
    icon: Icons.mic_rounded,
    titleEnglish: 'Offline voice commands',
    titleFilipino: 'Offline na voice commands',
    summaryEnglish: 'Navigate and hear schedules without internet.',
    summaryFilipino:
        'Mag-navigate at makinig sa iskedyul kahit walang internet.',
    itemsEnglish: [
      'Enable Voice Navigation in Settings, tap the microphone, and wait until the listening prompt finishes.',
      'Schedule: “What is my medicine schedule?” or “Ano ang mga gamot ko?”',
      'Time of day: “Anong iinumin ko ng umaga?” or “Night medicine.”',
      'Next dose: “Anong susunod na gamot ko?” or “What is my next medication?”',
      'Navigation: say “Scan,” “Home,” “Settings,” or “Help.”',
      'More navigation: say “Open the camera,” “Open my profile,” “User manual,” or “Accessibility settings.”',
      'Guidance: say “Where am I?” or “Read this screen.”',
      'After a dose: say “I took my medicine” to review and confirm a due dose.',
      'Name a dose: say “I took Biogesic” or “Mark Biogesic as taken,” then confirm the dose on screen.',
      'Remove a medicine: say “I do not want to take Biogesic anymore.” Confirm the removal on screen.',
      'Move a dose: say “Move Biogesic to 8 AM.” The next pending dose time will change.',
      'Speech controls: “Lakasan ang boses,” “Hinaan ang boses,” or “Ulitin mo.”',
      'The voice package needs internet only for its first download. Recognition stays on the device afterward.',
    ],
    itemsFilipino: [
      'I-on ang Voice Navigation sa Settings, pindutin ang mikropono, at hintaying matapos ang listening prompt.',
      'Iskedyul: “Ano ang mga gamot ko?” o “What is my medicine schedule?”',
      'Oras ng araw: “Anong iinumin ko ng umaga?” o “Night medicine.”',
      'Susunod na gamot: “Anong susunod na gamot ko?” o “What is my next medication?”',
      'Navigation: sabihin ang “Scan,” “Home,” “Settings,” o “Tulong.”',
      'Iba pang navigation: sabihin ang “Buksan ang camera,” “Profile ko,” “Gabay,” o “Accessibility settings.”',
      'Gabay: sabihin ang “Nasaan ako?” o “Basahin ang screen na ito.”',
      'Pagkatapos uminom: sabihin ang “Nainom ko na ang gamot” para suriin at kumpirmahin ang dose.',
      'Sabihin ang “Na-inom ko na ang Biogesic” para piliin at kumpirmahin ang dose.',
      'Para mag-alis: sabihin ang “Hindi ko na iinumin ang Biogesic.” Kumpirmahin ang pag-alis sa screen.',
      'Para maglipat ng oras: sabihin ang “Lipat mo nga ng 8 AM yung Biogesic.” Ililipat ang susunod na pending dose.',
      'Boses: “Lakasan ang boses,” “Hinaan ang boses,” o “Ulitin mo.”',
      'Internet lang ang kailangan sa unang download ng voice package. Sa device ginagawa ang pagkilala pagkatapos nito.',
    ],
  ),
  _ManualChapter(
    icon: Icons.accessibility_new_rounded,
    titleEnglish: 'Accessibility and language',
    titleFilipino: 'Accessibility at wika',
    summaryEnglish: 'Choose display, speech, and language preferences.',
    summaryFilipino: 'Piliin ang display, boses, at wikang mas komportable.',
    itemsEnglish: [
      'Standard mode uses the compact interface. Elder mode increases control and text sizes. Vision Loss mode emphasizes spoken guidance.',
      'Voice Navigation is a separate switch and remains off when you turn it off.',
      'Adjust voice volume, speed, pitch, and announcement detail in Settings.',
      'Choose English or Filipino for spoken responses.',
    ],
    itemsFilipino: [
      'Compact ang Standard mode. Mas malaki ang controls at text sa Elder mode. Mas binibigyang-diin ng Vision Loss mode ang gabay na binabasa.',
      'Hiwalay na switch ang Voice Navigation at mananatiling off kapag pinatay mo ito.',
      'Baguhin sa Settings ang volume, bilis, pitch, at detalye ng mga announcement.',
      'Piliin ang English o Filipino para sa binabasang sagot.',
    ],
  ),
  _ManualChapter(
    icon: Icons.build_circle_outlined,
    titleEnglish: 'Troubleshooting',
    titleFilipino: 'Kapag may problema',
    summaryEnglish: 'Quick checks for scanning, voice, and reminders.',
    summaryFilipino:
        'Mga mabilis na pagsusuri para sa scan, boses, at paalala.',
    itemsEnglish: [
      'Voice does not hear you: check microphone permission, move away from noise, speak after the prompt, and keep the phone within arm’s reach.',
      'Label is unclear: clean the camera lens, add light, avoid glare, and keep the package steady.',
      'An alarm is missing or quiet: enable Medication alarms, allow Alarms & reminders and notifications for MediSense, and check the phone’s Alarm volume.',
      'A command is misunderstood: use a shorter phrase such as “Morning medicine,” “Scan,” or “Settings.”',
    ],
    itemsFilipino: [
      'Hindi ka marinig: suriin ang microphone permission, lumayo sa ingay, magsalita pagkatapos ng prompt, at ilapit ang telepono.',
      'Malabo ang label: linisin ang camera lens, dagdagan ang ilaw, iwasan ang glare, at huwag igalaw ang pakete.',
      'Walang alarm o mahina ito: i-on ang Medication alarms, payagan ang Alarms & reminders at notifications para sa MediSense, at suriin ang Alarm volume ng telepono.',
      'Maling command ang narinig: gumamit ng mas maikling salita tulad ng “Morning medicine,” “Scan,” o “Settings.”',
    ],
  ),
];
