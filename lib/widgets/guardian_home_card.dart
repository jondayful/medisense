import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/database_helper.dart';
import '../models/user.dart';
import '../services/supabase_sync_service.dart';
import '../theme/app_theme.dart';

/// A compact, role-specific shortcut from the guardian's Home dashboard.
class GuardianHomeCard extends StatefulWidget {
  final String guardianId;
  final bool large;

  const GuardianHomeCard({
    super.key,
    required this.guardianId,
    this.large = false,
  });

  @override
  State<GuardianHomeCard> createState() => _GuardianHomeCardState();
}

class _GuardianHomeCardState extends State<GuardianHomeCard> {
  late Future<_GuardianHomeSummary> _summary;

  @override
  void initState() {
    super.initState();
    _summary = _loadSummary();
  }

  @override
  void didUpdateWidget(covariant GuardianHomeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.guardianId != widget.guardianId) {
      _summary = _loadSummary();
    }
  }

  Future<_GuardianHomeSummary> _loadSummary() async {
    final db = DatabaseHelper();
    final pairingsById = {
      for (final pairing in await db.getPairingsForGuardian(widget.guardianId))
        pairing.id: pairing,
    };
    try {
      final remotePairings = await SupabaseSyncService().fetchPairingRequests(
        userId: widget.guardianId,
        userEmail: '',
      );
      // Supabase is authoritative. A revoked local pairing must not continue
      // to select another patient's medication on the home card.
      pairingsById.clear();
      for (final pairing in remotePairings) {
        pairingsById[pairing.id] = pairing;
        await db.insertPairing(pairing);
      }
    } catch (error) {
      debugPrint('GuardianHome: could not refresh pairings - $error');
    }
    final pairings =
        pairingsById.values
            .where((pairing) => pairing.status == PairingStatus.accepted)
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (pairings.isEmpty) return const _GuardianHomeSummary();

    final pairing = pairings.first;
    final profileName = await SupabaseSyncService().getPairedPatientName(
      pairing.patientId,
    );
    final name = profileName ?? 'your patient';

    var remoteMeds = <Map<String, dynamic>>[];
    var remoteLogs = <Map<String, dynamic>>[];
    var cloudLoaded = false;
    try {
      final sync = SupabaseSyncService();
      remoteMeds = await sync.fetchPatientMedications(pairing.patientId);
      remoteLogs = await sync.fetchPatientLogs(pairing.patientId);
      cloudLoaded = true;
    } catch (error) {
      debugPrint('GuardianHome: could not refresh patient schedule - $error');
    }
    if (!cloudLoaded) {
      return _GuardianHomeSummary(
        patientName: name,
        additionalPatients: pairings.length - 1,
        cloudUnavailable: true,
      );
    }
    final nowDate = DateTime.now();
    final todayStart = DateTime(
      nowDate.year,
      nowDate.month,
      nowDate.day,
    ).millisecondsSinceEpoch;
    final statuses = <String, String>{};
    for (final log in remoteLogs) {
      final timestamp = log['timestamp'];
      if (timestamp is num && timestamp.toInt() >= todayStart) {
        final scheduleId = log['scheduleId']?.toString();
        if (scheduleId != null) statuses[scheduleId] = log['status'].toString();
      }
    }
    var notRecorded = 0;
    var scheduled = 0;
    for (final medication in remoteMeds) {
      final schedules = medication['schedules'];
      if (schedules is! List) continue;
      for (final value in schedules) {
        if (value is! Map) continue;
        final hour = value['hour'];
        final minute = value['minute'];
        if (hour is! num || minute is! num) continue;
        scheduled++;
        final scheduleId = value['id']?.toString();
        if (scheduleId == null || statuses[scheduleId] != 'taken') {
          notRecorded++;
        }
      }
    }
    return _GuardianHomeSummary(
      patientName: name,
      additionalPatients: pairings.length - 1,
      notRecordedDoses: notRecorded,
      scheduledDoses: scheduled,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = AppTheme.surfaceColor(context);
    final border = AppTheme.borderColor(context);
    final accent = isDark ? AppTheme.darkAccentGreen : AppTheme.accentGreen;
    final titleSize = widget.large ? 21.0 : 17.0;
    final bodySize = widget.large ? 16.0 : 13.0;

    return FutureBuilder<_GuardianHomeSummary>(
      future: _summary,
      builder: (context, snapshot) {
        final summary = snapshot.data ?? const _GuardianHomeSummary();
        final isLoading = snapshot.connectionState == ConnectionState.waiting;
        final hasPatient = summary.patientName != null;
        final title = hasPatient
            ? 'Check in on ${summary.patientName}'
            : 'Connect with a patient';
        final subtitle = isLoading
            ? 'Loading their latest schedule…'
            : !hasPatient
            ? 'Pair an account to keep their medication schedule close.'
            : summary.cloudUnavailable
            ? 'Care data is unavailable. Open to retry.'
            : summary.notRecordedDoses > 0
            ? summary.notRecordedDoses == 1
                  ? '1 scheduled dose is not recorded taken.'
                  : '${summary.notRecordedDoses} scheduled doses are not recorded taken.'
            : summary.scheduledDoses == 0
            ? 'No active medicines on their schedule yet.'
            : 'All scheduled doses are recorded taken.';

        return Semantics(
          button: true,
          label: '$title. $subtitle Open Guardian dashboard.',
          child: Material(
            color: surface,
            borderRadius: BorderRadius.circular(22),
            child: InkWell(
              onTap: () => context.go('/guardian'),
              borderRadius: BorderRadius.circular(22),
              child: Container(
                constraints: BoxConstraints(minHeight: widget.large ? 100 : 84),
                padding: EdgeInsets.symmetric(
                  horizontal: widget.large ? 18 : 16,
                  vertical: widget.large ? 16 : 14,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: border),
                ),
                child: Row(
                  children: [
                    Container(
                      width: widget.large ? 54 : 46,
                      height: widget.large ? 54 : 46,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        Icons.health_and_safety_outlined,
                        color: accent,
                        size: widget.large ? 29 : 25,
                      ),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            softWrap: true,
                            style: AppTheme.textStyle(
                              fontSize: titleSize,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.primaryTextColor(context),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            subtitle,
                            softWrap: true,
                            style: AppTheme.textStyle(
                              fontSize: bodySize,
                              color: AppTheme.secondaryTextColor(context),
                            ),
                          ),
                          if (summary.additionalPatients > 0) ...[
                            const SizedBox(height: 5),
                            Text(
                              '+ ${summary.additionalPatients} more linked ${summary.additionalPatients == 1 ? 'person' : 'people'}',
                              style: AppTheme.textStyle(
                                fontSize: bodySize - 1,
                                fontWeight: FontWeight.w600,
                                color: accent,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.chevron_right_rounded, color: accent, size: 28),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GuardianHomeSummary {
  final String? patientName;
  final int additionalPatients;
  final int notRecordedDoses;
  final int scheduledDoses;
  final bool cloudUnavailable;

  const _GuardianHomeSummary({
    this.patientName,
    this.additionalPatients = 0,
    this.notRecordedDoses = 0,
    this.scheduledDoses = 0,
    this.cloudUnavailable = false,
  });
}
