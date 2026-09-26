import 'package:url_launcher/url_launcher.dart';

import 'supabase_service.dart';

class SubscriptionPlan {
  final String id;
  final String title;
  final String price;
  final String description;

  const SubscriptionPlan({
    required this.id,
    required this.title,
    required this.price,
    required this.description,
  });
}

class SubscriptionService {
  static const premiumMonthly = SubscriptionPlan(
    id: 'premium_monthly',
    title: 'Premium monthly',
    price: '₱99 / month',
    description:
        'Unlimited cloud scans, better OCR, priority alerts, and voice profiles.',
  );

  static const guardianAnnual = SubscriptionPlan(
    id: 'guardian_annual',
    title: 'Guardian annual',
    price: '₱599 / year',
    description:
        'Guardian dashboard, advanced analytics, and multi-patient support.',
  );

  Future<bool> openCheckout(SubscriptionPlan plan) async {
    final result = await SupabaseService.client.functions.invoke(
      'create-paymongo-checkout',
      body: {'planId': plan.id},
    );
    final data = Map<String, dynamic>.from(result.data as Map? ?? {});
    final url = data['checkoutUrl'];
    if (url is! String || url.isEmpty) {
      throw StateError('PayMongo did not return a checkout URL.');
    }
    return launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Future<Map<String, dynamic>?> getEntitlement(String userId) async {
    final result = await SupabaseService.client
        .from('profiles')
        .select()
        .eq('id', userId)
        .maybeSingle();
    return result == null ? null : Map<String, dynamic>.from(result);
  }
}
