import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/accessibility_mode.dart';
import '../providers/app_state_provider.dart';
import '../theme/app_theme.dart';

enum LegalDocumentType { terms, privacy }

class LegalDocumentScreen extends StatelessWidget {
  final LegalDocumentType type;

  const LegalDocumentScreen({super.key, required this.type});

  bool get _isTerms => type == LegalDocumentType.terms;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accessible = context
        .watch<AppStateProvider>()
        .accessibilityMode
        .usesLargeText;
    final title = _isTerms ? 'Terms of Service' : 'Privacy Policy';
    final bodyColor = isDark
        ? AppTheme.darkTextSecondary
        : AppTheme.textSecondary;
    final headingColor = isDark
        ? AppTheme.darkTextPrimary
        : AppTheme.textPrimary;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            accessible ? 20 : 24,
            24,
            accessible ? 20 : 24,
            40,
          ),
          children: [
            Text(
              title,
              style: AppTheme.textStyle(
                fontSize: accessible ? 36 : 30,
                fontWeight: FontWeight.w800,
                color: headingColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Last updated: September 29, 2026',
              style: AppTheme.textStyle(
                fontSize: accessible ? 17 : 14,
                color: bodyColor,
              ),
            ),
            const SizedBox(height: 24),
            ...(_isTerms ? _terms : _privacy).map(
              (section) => _LegalSection(
                heading: section.$1,
                text: section.$2,
                headingColor: headingColor,
                bodyColor: bodyColor,
                accessible: accessible,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: (isDark ? AppTheme.darkCardSurface : AppTheme.muted),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                'MediSense is a medication organization tool. Check the label and your clinician’s instructions before taking a dose.',
                style: AppTheme.textStyle(
                  fontSize: accessible ? 18 : 14,
                  fontWeight: FontWeight.w600,
                  color: bodyColor,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const _terms = <(String, String)>[
    (
      'Who provides MediSense',
      'MediSense is a capstone project developed by Matech for academic demonstration and testing. It is not a publicly released service. You can contact us about these Terms or your test account at support@matech.uno.',
    ),
    (
      'What MediSense provides',
      'MediSense lets you record medication schedules, scan labels, receive reminders, and share schedule and dose activity with an accepted guardian. It does not prescribe, diagnose, verify that a medicine is safe for you, or replace a clinician, pharmacist, or emergency service.',
    ),
    (
      'Check every medicine entry',
      'OCR, speech recognition, and schedule suggestions can make mistakes. Compare every medicine name, strength, dose, time, and expiration date with the original packaging and your prescription before saving or taking a medicine. Do not use an expired medicine without advice from a pharmacist or clinician.',
    ),
    (
      'Account and guardian access',
      'Keep your sign-in details private and your account information accurate. A guardian may view your medication schedule and recorded dose activity only after you accept a pairing request. Accept requests only from people you trust. Both parties must use the app lawfully and respect the patient’s privacy.',
    ),
    (
      'Payments',
      'If you choose a paid plan, it removes the app\'s daily limit on optional cloud OCR fallback for the stated period. It does not guarantee a successful cloud scan or faster recognition. PayMongo processes payment details. The app grants the plan period only after payment is verified; it does not automatically renew the plan. Payment and refund rights also depend on the checkout terms and applicable law.',
    ),
    (
      'Reminders and availability',
      'Phone settings, battery restrictions, permissions, connectivity, and service outages may delay or prevent alarms, scans, synchronization, or guardian messages. Keep a separate reliable record of prescriptions and use another reminder method when missing a dose could be harmful.',
    ),
    (
      'Inactive accounts',
      'For a hosted version of this project, the proposed account lifecycle is 12 months of inactivity followed by a further 12-month closure period. Cloud account data would be deleted after 24 months of inactivity, subject to the Privacy Policy. Automatic account closure is not part of the current prototype.',
    ),
    (
      'Governing law',
      'These Terms are governed by the laws of the Philippines, subject to any mandatory rights you have under applicable law.',
    ),
    (
      'Changes and questions',
      'We may update these Terms when the service changes and will show the current version in the app. For questions or account assistance, email support@matech.uno.',
    ),
  ];

  static const _privacy = <(String, String)>[
    (
      'Who is responsible',
      'Matech develops MediSense as a capstone project for academic demonstration and testing. This policy explains the data the prototype may process when its features are used. For privacy questions or requests, email support@matech.uno.',
    ),
    (
      'Data MediSense uses',
      'Your account name, email, role, guardian pairings, medication names, strengths, schedules, expiration dates, and dose timestamps support the features you choose. The app also stores accessibility, voice, and alarm preferences on your device. Medication and dose records can reveal sensitive health information.',
    ),
    (
      'Why data is used and shared',
      'We use account data to sign you in, medication data to maintain schedules and alarms, and dose timestamps to show when a dose was marked taken. When you accept a guardian pairing, that guardian can view your synced medication and dose activity and can send reminders. We do not sell personal information or use medication data for advertising.',
    ),
    (
      'Scanning and voice',
      'The camera captures label images for text recognition. On-device ML Kit is used for local OCR. Cloud scan assistance is off by default; if you enable it in Settings and a local scan is incomplete, the captured image may be sent directly to Google Cloud Vision for text extraction. You can withdraw this choice in Settings. Android voice commands require a downloaded speech model; iOS voice commands depend on available on-device language support. Device text-to-speech speaks reminders. Review scan results before saving.',
    ),
    (
      'Service providers and storage',
      'Supabase stores account profiles, synced medication schedules, pairings, guardian reminders, and dose logs. Google Sign-In may authenticate an account. PayMongo handles optional payments; MediSense does not store card or e-wallet credentials. Local device storage keeps a working copy so the app can operate and retry synchronization.',
    ),
    (
      'Your controls and rights',
      'You can change voice and accessibility settings, turn off cloud scan assistance, and stop sharing by managing guardian pairings. Uninstalling removes the app from your device but does not automatically erase synced cloud records. To request access, correction, deletion, or other applicable privacy rights, use Privacy and data requests in Settings or email support@matech.uno. Do not include medicine details in an initial email. We may verify your identity before acting on a request.',
    ),
    (
      'Inactive account retention',
      'For a hosted version of this project, the proposed cloud-data retention period is 24 months after the last account activity: 12 months of inactivity, followed by a further 12-month closure period. At the end of that period, the intended process is to delete the cloud profile, medication schedules, guardian pairings, reminders, and dose records, except data that must be kept for a legal obligation or legitimate legal claim. The current prototype does not automatically track inactivity or close accounts. Data stored on your device may remain until you clear app data or uninstall the app.',
    ),
    (
      'Security',
      'Account access uses Supabase authentication and row-level access rules for patient and accepted-guardian records. Network transmission uses encrypted connections. No internet service can promise absolute security. Report a suspected privacy or security issue to support@matech.uno.',
    ),
  ];
}

class _LegalSection extends StatelessWidget {
  final String heading;
  final String text;
  final Color headingColor;
  final Color bodyColor;
  final bool accessible;

  const _LegalSection({
    required this.heading,
    required this.text,
    required this.headingColor,
    required this.bodyColor,
    required this.accessible,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            heading,
            style: AppTheme.textStyle(
              fontSize: accessible ? 24 : 20,
              fontWeight: FontWeight.w800,
              color: headingColor,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            text,
            style: AppTheme.textStyle(
              fontSize: accessible ? 19 : 16,
              color: bodyColor,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
