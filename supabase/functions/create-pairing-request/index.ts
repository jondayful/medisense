import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';

const jsonHeaders = { ...corsHeaders, 'Content-Type': 'application/json' };
const htmlEscapes: Record<string, string> = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;',
};
const escapeHtml = (value: string) => value.replace(/[&<>"']/g, (char) => htmlEscapes[char] ?? char);

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') {
    return Response.json({ error: 'Method not allowed.' }, { status: 405, headers: jsonHeaders });
  }

  const authHeader = request.headers.get('Authorization');
  const accessToken = authHeader?.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!accessToken) {
    return Response.json({ error: 'Sign in to your Guardian account and try again.' }, { status: 401, headers: jsonHeaders });
  }

  const projectUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const resendApiKey = Deno.env.get('RESEND_API_KEY');
  const fromEmail = Deno.env.get('RESEND_FROM_EMAIL') ?? 'MediSense <noreply@matech.uno>';
  if (!projectUrl || !anonKey || !serviceRoleKey || !resendApiKey) {
    console.error('Pairing invitation configuration is incomplete.');
    return Response.json({ error: 'Invitations are temporarily unavailable. Please try again later.' }, { status: 503, headers: jsonHeaders });
  }

  const authClient = createClient(projectUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
  const { data: userResult, error: authError } = await authClient.auth.getUser(accessToken);
  if (authError || !userResult.user || !userResult.user.email) {
    return Response.json({ error: 'Your session expired. Sign in again and retry.' }, { status: 401, headers: jsonHeaders });
  }

  let body: { patient_email?: unknown };
  try {
    body = await request.json();
  } catch {
    return Response.json({ error: 'Enter a valid patient email address.' }, { status: 400, headers: jsonHeaders });
  }
  const patientEmail = typeof body.patient_email === 'string'
    ? body.patient_email.trim().toLowerCase()
    : '';
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(patientEmail)) {
    return Response.json({ error: 'Enter a valid patient email address.' }, { status: 400, headers: jsonHeaders });
  }

  const admin = createClient(projectUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: guardian, error: guardianError } = await admin
    .from('profiles')
    .select('id, email, name, role')
    .eq('id', userResult.user.id)
    .maybeSingle();
  if (guardianError) {
    console.error('Guardian profile lookup failed:', guardianError.code, guardianError.message);
    return Response.json({ error: 'Could not verify your Guardian profile. Please try again.' }, { status: 500, headers: jsonHeaders });
  }
  if (!guardian || guardian.role !== 'guardian') {
    return Response.json({ error: 'Only a Guardian account can send pairing invitations.' }, { status: 403, headers: jsonHeaders });
  }
  if (guardian.email?.toLowerCase() === patientEmail) {
    return Response.json({ error: 'You cannot pair your account with itself.' }, { status: 400, headers: jsonHeaders });
  }

  const { data: patient, error: patientError } = await admin
    .from('profiles')
    .select('id, email, name, role')
    .eq('email', patientEmail)
    .maybeSingle();
  if (patientError) {
    console.error('Patient lookup failed:', patientError.code);
    return Response.json({ error: 'Could not verify that account. Please try again.' }, { status: 500, headers: jsonHeaders });
  }
  if (!patient || patient.role !== 'patient') {
    // Do not let a Guardian account enumerate patient email addresses.
    return Response.json({ status: 'request_processed' }, { status: 200, headers: jsonHeaders });
  }

  const { data: existing, error: existingError } = await admin
    .from('pairings')
    .select('id, status')
    .eq('guardian_id', guardian.id)
    .eq('patient_id', patient.id)
    .in('status', ['pending', 'accepted'])
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (existingError) {
    console.error('Pairing lookup failed:', existingError.code);
    return Response.json({ error: 'Could not check existing invitations. Please try again.' }, { status: 500, headers: jsonHeaders });
  }
  if (existing?.status === 'accepted') {
    return Response.json({ status: 'request_processed' }, { status: 200, headers: jsonHeaders });
  }

  const pairing = existing ?? {
    id: crypto.randomUUID(),
    guardian_id: guardian.id,
    guardian_email: guardian.email,
    patient_id: patient.id,
    patient_email: patient.email,
    // Kept for compatibility with the existing table; never shown to users.
    pairing_code: crypto.randomUUID(),
    status: 'pending',
    created_at: new Date().toISOString(),
  };
  if (!existing) {
    const { error: insertError } = await admin.from('pairings').insert(pairing);
    if (insertError) {
      console.error('Pairing insert failed:', insertError.code, insertError.message);
      return Response.json({ error: 'Could not save the invitation. Please try again.' }, { status: 500, headers: jsonHeaders });
    }
  }

  const guardianName = escapeHtml(guardian.name?.trim() || guardian.email);
  const safeEmail = escapeHtml(patient.email);
  const pairingLinkUrl = `${projectUrl.replace(/\/$/, '')}/functions/v1/pairing-link?pairing_id=${encodeURIComponent(pairing.id)}`;
  const pairingEmailHtml = `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta charset="utf-8"></head><body style="margin:0;background:#F7F6F2;color:#282A25;font-family:Arial,Helvetica,sans-serif;padding:32px 16px"><main style="max-width:560px;margin:auto"><p style="font-size:24px;font-weight:700;margin:0;color:#30352D">MediSense</p><p style="font-size:11px;letter-spacing:1.5px;color:#747468;margin:5px 0 22px">YOUR MEDICATION COMPANION</p><section style="background:#fff;border:1px solid #DED8CF;border-radius:20px;padding:32px"><p style="font-size:11px;letter-spacing:1.5px;color:#53694B;font-weight:bold">GUARDIAN INVITATION</p><h1 style="font-size:26px;line-height:1.25;margin:12px 0">A Guardian wants to connect</h1><p style="font-size:16px;line-height:1.6;color:#54544C"><strong>${guardianName}</strong> (${escapeHtml(guardian.email)}) would like to connect with your MediSense account (${safeEmail}) and view your medication schedule and adherence information.</p><p style="font-size:16px;line-height:1.6;color:#54544C">Review the request in the app. Your information will only be shared if you accept.</p><p style="margin:26px 0"><a href="${pairingLinkUrl}" style="display:inline-block;background:#53694B;color:#fff;text-decoration:none;font-size:16px;font-weight:bold;padding:15px 24px;border-radius:12px">Review pairing request</a></p><p style="font-size:14px;line-height:1.6;color:#747468">If the button does not open MediSense, the next page provides an Open MediSense link. You can also sign in and check <strong>Guardian → Pending Requests</strong>.</p></section><p style="font-size:12px;color:#747468;line-height:1.6;padding:16px 4px">MediSense · matech.uno</p></main></body></html>`;
  const pairingEmailText = `${guardian.name?.trim() || guardian.email} invited you to connect on MediSense. Open this link to review the request: ${pairingLinkUrl}\n\nYour medication information is shared only if you accept. If you do not recognize this invitation, ignore this email.`;
  const emailResponse = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${resendApiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(Object.assign({
      from: fromEmail,
      to: [patient.email],
      subject: 'A MediSense Guardian wants to connect with you',
      html: `<!doctype html><html><body style="margin:0;background:#FDFCF8;color:#2C2C24;font-family:Arial,Helvetica,sans-serif;padding:32px 16px"><main style="max-width:560px;margin:auto"><p style="font-size:22px;font-weight:700;margin:0">MediSense</p><p style="font-size:11px;letter-spacing:1.5px;color:#747468;margin:5px 0 22px">YOUR MEDICATION COMPANION</p><section style="background:#fff;border:1px solid #DED8CF;border-radius:20px;padding:32px"><p style="font-size:11px;letter-spacing:1.5px;color:#5D7052;font-weight:bold">GUARDIAN INVITATION</p><h1 style="font-size:26px;line-height:1.25">A Guardian wants to connect</h1><p style="font-size:16px;line-height:1.6;color:#54544C"><strong>${guardianName}</strong> (${escapeHtml(guardian.email)}) would like to connect with your MediSense account${safeEmail ? ` (${safeEmail})` : ''} and view your medication schedule and adherence information.</p><p style="font-size:16px;line-height:1.6;color:#54544C">Open MediSense and go to <strong>Guardian → Pending Requests</strong> to accept or decline. Your information will only be shared if you accept.</p><p style="font-size:14px;line-height:1.6;color:#747468">If you don't recognize this person or weren't expecting this invitation, you can ignore this email.</p></section><p style="font-size:12px;color:#747468;line-height:1.6;padding:16px 4px">MediSense · matech.uno</p></main></body></html>`,
    }, { html: pairingEmailHtml, text: pairingEmailText })),
  });

  if (!emailResponse.ok) {
    console.error('Resend rejected pairing invitation:', emailResponse.status);
    if (!existing) {
      await admin.from('pairings').delete().eq('id', pairing.id).eq('status', 'pending');
    }
    return Response.json({ error: 'The invitation email could not be sent. Please try again later.' }, { status: 502, headers: jsonHeaders });
  }

  return Response.json({ status: 'request_processed' }, { status: 200, headers: jsonHeaders });
});
