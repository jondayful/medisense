import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../services/subscription_service.dart';
import '../theme/app_theme.dart';

class PaymentSuccessScreen extends StatefulWidget {
  const PaymentSuccessScreen({super.key});

  @override
  State<PaymentSuccessScreen> createState() => _PaymentSuccessScreenState();
}

class _PaymentSuccessScreenState extends State<PaymentSuccessScreen> {
  bool _checking = true;
  bool _activated = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshEntitlement(waitForWebhook: true));
  }

  Future<void> _refreshEntitlement({bool waitForWebhook = false}) async {
    if (mounted) setState(() => _checking = true);
    final auth = context.read<AuthProvider>();
    final service = SubscriptionService();

    for (var attempt = 0; attempt < (waitForWebhook ? 6 : 1); attempt++) {
      try {
        final profile = await service.getEntitlement(auth.userId);
        final expiresAt = DateTime.tryParse(
          profile?['subscription_expires_at']?.toString() ?? '',
        );
        final active =
            profile?['subscription_status'] == 'active' &&
            expiresAt != null &&
            expiresAt.isAfter(DateTime.now().toUtc());

        if (active) {
          auth.updateTier(profile?['tier'] as String? ?? 'Free');
          if (mounted) {
            setState(() {
              _activated = true;
              _checking = false;
            });
          }
          return;
        }
      } catch (error) {
        debugPrint('Could not refresh subscription after checkout: $error');
      }

      if (attempt + 1 < (waitForWebhook ? 6 : 1)) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }

    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();
    final active = _activated;
    final successColor = isDark ? AppTheme.darkSuccess : AppTheme.success;

    return Scaffold(
      appBar: AppBar(title: const Text('Payment received')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                active ? Icons.check_circle : Icons.hourglass_top_rounded,
                size: 80,
                color: successColor,
              ),
              const SizedBox(height: 24),
              Text(
                active ? 'Subscription activated' : 'Payment received',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                active
                    ? 'Your ${auth.tier} plan is active.'
                    : _checking
                    ? 'We are confirming your payment and updating your plan.'
                    : 'Your payment has returned to the app, but the subscription is not active yet. Check your connection and refresh shortly.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              if (_checking)
                const CircularProgressIndicator()
              else if (!active)
                OutlinedButton.icon(
                  onPressed: () => _refreshEntitlement(),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Refresh subscription status'),
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go('/profile'),
                child: const Text('Back to profile'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
