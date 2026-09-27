import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/user.dart';
import '../providers/auth_provider.dart';
import '../services/supabase_sync_service.dart';
import '../theme/app_theme.dart';

/// Patient's current guardian connection from the Supabase pairing records.
class PatientGuardianHomeCard extends StatefulWidget {
  const PatientGuardianHomeCard({super.key, this.large = false});
  final bool large;

  @override
  State<PatientGuardianHomeCard> createState() =>
      _PatientGuardianHomeCardState();
}

class _PatientGuardianHomeCardState extends State<PatientGuardianHomeCard> {
  String? _patientId;
  Future<List<String>>? _guardians;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.watch<AuthProvider>();
    if (_patientId == auth.userId) return;
    _patientId = auth.userId;
    _guardians = _loadGuardians(auth.userId, auth.userEmail);
  }

  Future<List<String>> _loadGuardians(String id, String email) async {
    if (id.isEmpty) return [];
    final sync = SupabaseSyncService();
    final pairings = await sync.fetchPairingRequests(
      userId: id,
      userEmail: email,
    );
    final accepted = pairings.where(
      (p) => p.patientId == id && p.status == PairingStatus.accepted,
    );
    final names = <String>[];
    for (final pairing in accepted) {
      final profile = await sync.getUserProfile(pairing.guardianId);
      final name = profile?['name']?.toString().trim();
      names.add(name != null && name.isNotEmpty ? name : pairing.guardianEmail);
    }
    return names;
  }

  @override
  Widget build(BuildContext context) {
    final accent = AppTheme.actionColor(context);
    final primary = AppTheme.primaryTextColor(context);
    final secondary = AppTheme.secondaryTextColor(context);
    return FutureBuilder<List<String>>(
      future: _guardians,
      builder: (context, snapshot) {
        final guardians = snapshot.data ?? const <String>[];
        final connected = guardians.isNotEmpty;
        return Card(
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: AppTheme.borderColor(context)),
          ),
          child: Padding(
            padding: EdgeInsets.all(widget.large ? 24 : 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      connected
                          ? Icons.people_rounded
                          : Icons.person_add_alt_1_rounded,
                      color: accent,
                      size: widget.large ? 36 : 28,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'YOUR GUARDIAN',
                            style: AppTheme.microLabel(color: accent),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            connected
                                ? guardians.join(', ')
                                : 'Add your Guardian',
                            style: AppTheme.textStyle(
                              fontSize: widget.large ? 24 : 18,
                              fontWeight: FontWeight.w700,
                              color: primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  connected
                      ? 'Connected to your care team.'
                      : snapshot.hasError
                      ? 'Connection unavailable. Manage guardians to retry.'
                      : 'Review invitations and connected guardians.',
                  style: AppTheme.textStyle(
                    fontSize: widget.large ? 18 : 14,
                    color: secondary,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    await context.push('/guardian');
                    if (mounted && _patientId != null) {
                      final auth = this.context.read<AuthProvider>();
                      setState(
                        () => _guardians = _loadGuardians(
                          _patientId!,
                          auth.userEmail,
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.manage_accounts_rounded),
                  label: const Text('Manage Guardian'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
