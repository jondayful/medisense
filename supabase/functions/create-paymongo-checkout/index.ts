import { createClient } from 'npm:@supabase/supabase-js@2';
import { plans, paymongoAuth } from '../_shared/paymongo.ts';

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '');
  if (!token) return json({ error: 'Sign in first.' }, 401);

  const url = Deno.env.get('SUPABASE_URL')!;
  const publicClient = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const { data: { user } } = await publicClient.auth.getUser(token);
  if (!user) return json({ error: 'Sign in first.' }, 401);

  const { planId } = await req.json();
  const plan = plans[planId];
  if (!plan) return json({ error: 'Unknown plan.' }, 400);
  const secretKey = Deno.env.get('PAYMONGO_SECRET_KEY');
  const baseUrl = Deno.env.get('PAYMONGO_RETURN_BASE_URL');
  if (!secretKey || !baseUrl) return json({ error: 'PayMongo is not configured.' }, 500);

  const referenceNumber = `medisense_${user.id}_${planId}_${crypto.randomUUID()}`;
  const response = await fetch('https://api.paymongo.com/v2/checkout_sessions', {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      Authorization: paymongoAuth(secretKey),
      'Content-Type': 'application/json',
      'Idempotency-Key': referenceNumber,
    },
    body: JSON.stringify({ data: { attributes: {
      billing: { name: user.user_metadata?.['full_name'] || user.email || 'MediSense user', email: user.email || '' },
      cancel_url: `${baseUrl}/payment-cancelled`,
      success_url: `${baseUrl}/payment-result`,
      description: plan.name,
      reference_number: referenceNumber,
      send_email_receipt: false,
      show_description: true,
      show_line_items: true,
      payment_method_types: ['card', 'gcash', 'qrph'],
      metadata: { userId: user.id, planId, referenceNumber },
      line_items: [{ amount: plan.amount, currency: 'PHP', name: plan.name, quantity: 1 }],
    } } }),
  });
  const payload = await response.json();
  if (!response.ok) return json({ error: 'Could not start checkout.' }, 502);
  const checkout = payload?.data;
  if (!checkout?.id || !checkout?.attributes?.checkout_url) return json({ error: 'PayMongo returned no checkout URL.' }, 502);

  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { error } = await admin.from('payment_sessions').insert({
    reference_number: referenceNumber,
    user_id: user.id,
    plan_id: planId,
    tier: plan.tier,
    amount: plan.amount,
    currency: 'PHP',
    checkout_session_id: checkout.id,
    livemode: secretKey.startsWith('sk_live_'),
    status: 'pending',
  });
  if (error) return json({ error: 'Could not record checkout.' }, 500);
  return json({ checkoutUrl: checkout.attributes.checkout_url, referenceNumber });
});
