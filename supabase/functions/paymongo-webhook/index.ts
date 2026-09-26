import { createClient } from 'npm:@supabase/supabase-js@2';
import {
  constantTimeEqual,
  findReference,
  hmacSha256,
  plans,
} from '../_shared/paymongo.ts';

const json = (body: unknown, status = 200) =>
  Response.json(body, { status });

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }

  const rawBody = await req.text();
  const signatureHeader = req.headers.get('Paymongo-Signature') || '';
  const signatureParts = Object.fromEntries(
    signatureHeader.split(',').map((part) => {
      const [key, value = ''] = part.trim().split('=');
      return [key, value];
    }),
  );
  const timestamp = signatureParts.t;
  const secret = Deno.env.get('PAYMONGO_WEBHOOK_SECRET') || '';
  const nowSeconds = Math.floor(Date.now() / 1000);
  const timestampSeconds = Number(timestamp);
  const expected = timestamp && secret
    ? await hmacSha256(secret, `${timestamp}.${rawBody}`)
    : '';
  let event: Record<string, any>;
  try {
    event = JSON.parse(rawBody);
  } catch {
    return json({ error: 'Invalid JSON payload.' }, 400);
  }

  const eventEnvelope = event.data ?? event;
  const attributes = eventEnvelope?.attributes ?? {};
  const eventType = attributes.type ?? eventEnvelope?.type ?? null;
  const livemode = attributes.livemode ?? eventEnvelope?.livemode ?? false;
  const providedSignature = livemode
    ? signatureParts.li
    : signatureParts.te;

  if (
    !timestamp || !Number.isFinite(timestampSeconds) || !providedSignature ||
    Math.abs(nowSeconds - timestampSeconds) > 300 || !secret ||
    !constantTimeEqual(expected, providedSignature)
  ) {
    return json({ error: 'Invalid webhook signature.' }, 401);
  }

  const supportedEvents = new Set([
    'checkout_session.payment.paid',
    'payment.paid',
    'payment_intent.succeeded',
    'payment.failed',
    'payment.refunded',
    'refund.succeeded',
  ]);
  if (!supportedEvents.has(eventType)) {
    return json({ received: true, ignored: true });
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceRoleKey) {
    console.error('PayMongo webhook missing Supabase server configuration.');
    return json({ error: 'Webhook server is not configured.' }, 500);
  }
  const admin = createClient(supabaseUrl, serviceRoleKey);
  const eventId = eventEnvelope?.id || event.id ||
    (await hmacSha256(secret, rawBody));
  const eventLivemode = livemode === true;
  const resource = attributes.data ?? eventEnvelope?.data ?? null;
  const reference = resource?.attributes?.reference_number ??
    resource?.attributes?.metadata?.referenceNumber ?? findReference(event);

  // Insert a claim before processing to guard against concurrent duplicate
  // deliveries. On any processing failure, remove it so PayMongo can retry.
  const { error: claimError } = await admin.from('paymongo_events').insert({
    event_id: eventId,
    event_type: eventType,
    livemode: eventLivemode,
  });
  if (claimError?.code === '23505') return json({ received: true, duplicate: true });
  if (claimError) {
    console.error('Could not claim PayMongo event:', claimError.message);
    return json({ error: 'Could not record webhook event.' }, 500);
  }

  const releaseClaim = async () => {
    const { error } = await admin.from('paymongo_events')
      .delete()
      .eq('event_id', eventId);
    if (error) console.error('Could not release failed event claim:', error.message);
  };

  try {
    let query = admin.from('payment_sessions').select('*').limit(1);
    const { data: sessions, error: sessionError } = reference
      ? await query.eq('reference_number', reference)
      : await query.eq('checkout_session_id', resource?.id || '');

    if (sessionError) throw new Error(`Payment lookup failed: ${sessionError.message}`);
    const session = sessions?.[0];
    if (!session) throw new Error('No matching payment session was found.');
    if (session.livemode !== eventLivemode) {
      throw new Error('Webhook test/live mode does not match the checkout session.');
    }

    if (
      eventType === 'checkout_session.payment.paid' ||
      eventType === 'payment.paid' ||
      eventType === 'payment_intent.succeeded'
    ) {
      const plan = plans[session.plan_id];
      if (!plan) throw new Error('The payment session has an unknown plan.');

      const { data: profile, error: profileReadError } = await admin
        .from('profiles')
        .select('subscription_expires_at, paymongo_reference')
        .eq('id', session.user_id)
        .maybeSingle();
      if (profileReadError) {
        throw new Error(`Profile lookup failed: ${profileReadError.message}`);
      }
      if (!profile) throw new Error('No profile exists for the paid account.');

      const currentExpiry = profile.subscription_expires_at
        ? new Date(profile.subscription_expires_at).getTime()
        : 0;
      // If the profile write succeeded but a later write failed, a delivery
      // retry must not grant the same purchase period a second time.
      const alreadyApplied = profile.paymongo_reference === session.reference_number;
      const expiresAt = alreadyApplied && Number.isFinite(currentExpiry)
        ? new Date(currentExpiry).toISOString()
        : new Date(Math.max(Date.now(), Number.isFinite(currentExpiry) ? currentExpiry : 0) +
          plan.durationDays * 86400000).toISOString();

      const { data: updatedProfile, error: profileUpdateError } = await admin
        .from('profiles')
        .update({
          tier: plan.tier,
          subscription_plan: session.plan_id,
          subscription_status: 'active',
          subscription_expires_at: expiresAt,
          paymongo_reference: session.reference_number,
        })
        .eq('id', session.user_id)
        .select('id')
        .maybeSingle();
      if (profileUpdateError) {
        throw new Error(`Profile update failed: ${profileUpdateError.message}`);
      }
      if (!updatedProfile) throw new Error('The subscription profile was not updated.');

      const { data: updatedSession, error: sessionUpdateError } = await admin
        .from('payment_sessions')
        .update({ status: 'paid', paid_at: new Date().toISOString() })
        .eq('reference_number', session.reference_number)
        .select('reference_number')
        .maybeSingle();
      if (sessionUpdateError) {
        throw new Error(`Payment status update failed: ${sessionUpdateError.message}`);
      }
      if (!updatedSession) throw new Error('The payment session was not marked paid.');
    } else {
      const { error: statusError } = await admin
        .from('payment_sessions')
        .update({ status: eventType })
        .eq('reference_number', session.reference_number);
      if (statusError) throw new Error(`Payment status update failed: ${statusError.message}`);
    }

    console.log(`Processed PayMongo event type: ${eventType}`);
    return json({ received: true, processed: true });
  } catch (error) {
    await releaseClaim();
    console.error(
      `PayMongo event processing failed (${eventType}):`,
      error instanceof Error ? error.message : String(error),
    );
    return json({ error: 'Payment event could not be processed.' }, 500);
  }
});
