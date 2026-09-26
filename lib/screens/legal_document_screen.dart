import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

enum LegalDocumentType { terms, privacy }

class LegalDocumentScreen extends StatelessWidget {
  final LegalDocumentType type;

  const LegalDocumentScreen({super.key, required this.type});

  bool get _isTerms => type == LegalDocumentType.terms;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
          children: [
            Text(
              title,
              style: AppTheme.textStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                color: headingColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Last updated: September 18, 2026',
              style: AppTheme.textStyle(fontSize: 14, color: bodyColor),
            ),
            const SizedBox(height: 24),
            ...(_isTerms ? _terms : _privacy).map(
              (section) => _LegalSection(
                heading: section.$1,
                text: section.$2,
                headingColor: headingColor,
                bodyColor: bodyColor,
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
                'This in-app draft should be reviewed by a qualified legal professional before a public release.',
                style: AppTheme.textStyle(
                  fontSize: 14,
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
      'Using MediSense',
      'MediSense helps you organize medicine schedules, reminders, and label scans. It is not a medical device, does not diagnose conditions, and does not replace advice from a doctor, pharmacist, or emergency service.',
    ),
    (
      'Your responsibilities',
      'Check medicine names, dosage, timing, and instructions against the original prescription and packaging before taking any medicine. Use the app only for lawful purposes and keep your account details accurate.',
    ),
    (
      'Accounts and subscriptions',
      'You are responsible for protecting your sign-in credentials. Optional paid plans are processed through a payment provider and are activated only after payment is verified. Plan features, prices, and renewal terms are shown before checkout.',
    ),
    (
      'Availability',
      'We aim to keep MediSense available and accurate, but reminders, scans, network services, and voice features can fail or be unavailable. Keep another reliable record of important prescriptions and medication instructions.',
    ),
    (
      'Contact',
      'For questions about these terms, contact the MediSense project team through the support contact published with the app.',
    ),
  ];

  static const _privacy = <(String, String)>[
    (
      'Information we handle',
      'MediSense may handle your profile name, email address, accessibility preferences, medication schedules, reminder history, and label scan results. Voice commands and images are used only to provide the feature you request.',
    ),
    (
      'How information is used',
      'We use this information to sign you in, save your schedule, show reminders, provide accessibility features, and improve the reliability of the app. We do not sell personal information.',
    ),
    (
      'Storage and service providers',
      'Account and schedule data can be stored using Supabase services. Google Sign-In may be used to authenticate your account. If you choose a paid plan, PayMongo processes payment information; MediSense does not store card or e-wallet credentials.',
    ),
    (
      'Your choices',
      'You can change accessibility and voice preferences in Settings. You can remove local data by uninstalling the app and may request account-data help through the support contact published with the app.',
    ),
    (
      'Security',
      'We use reasonable safeguards, but no internet service can guarantee absolute security. Do not share your account password or payment details with anyone.',
    ),
  ];
}

class _LegalSection extends StatelessWidget {
  final String heading;
  final String text;
  final Color headingColor;
  final Color bodyColor;

  const _LegalSection({
    required this.heading,
    required this.text,
    required this.headingColor,
    required this.bodyColor,
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
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: headingColor,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            text,
            style: AppTheme.textStyle(
              fontSize: 16,
              color: bodyColor,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
