import 'package:url_launcher/url_launcher.dart';

import 'cloud_vision_service.dart';
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
        'Removes the app\'s daily limit on optional cloud OCR fallback for 31 days.',
  );

  static const guardianAnnual = SubscriptionPlan(
    id: 'guardian_annual',
    title: 'Annual cloud OCR',
    price: '₱599 / year',
    description:
        'Removes the app\'s daily limit on optional cloud OCR fallback for 365 days.',
  );

  Future<bool> openCheckout(SubscriptionPlan plan) async {
    if (!SupabaseService.isConfigured) {
      throw StateError('Account services are unavailable in this app build.');
    }
    if (!CloudVisionService.isConfiguredForThisBuild) {
      throw StateError('Cloud OCR is unavailable in this app build.');
    }
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
