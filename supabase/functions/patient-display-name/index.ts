import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';

const headers = { ...corsHeaders, 'Content-Type': 'application/json' };
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') {
    return Response.json({ error: 'Method not allowed.' }, { status: 405, headers });
  }

  const accessToken = request.headers.get('Authorization')?.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!accessToken) {
    return Response.json({ error: 'Sign in and try again.' }, { status: 401, headers });
  }

  const projectUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!projectUrl || !anonKey || !serviceRoleKey) {
    console.error('Patient display name configuration is incomplete.');
    return Response.json({ error: 'Patient name is temporarily unavailable.' }, { status: 503, headers });
  }

  const authClient = createClient(projectUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userResult, error: authError } = await authClient.auth.getUser(accessToken);
  if (authError || !userResult.user) {
    return Response.json({ error: 'Your session expired.' }, { status: 401, headers });
  }

  let body: { patient_id?: unknown };
  try {
    body = await request.json();
  } catch {
    return Response.json({ error: 'Invalid request.' }, { status: 400, headers });
  }
  const patientId = typeof body.patient_id === 'string' ? body.patient_id.trim() : '';
  if (!uuidPattern.test(patientId)) {
    return Response.json({ error: 'Invalid patient ID.' }, { status: 400, headers });
  }

  const admin = createClient(projectUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: pairing, error: pairingError } = await admin
    .from('pairings')
    .select('id')
    .eq('guardian_id', userResult.user.id)
    .eq('patient_id', patientId)
    .eq('status', 'accepted')
    .limit(1)
    .maybeSingle();
  if (pairingError) {
    console.error('Accepted pairing lookup failed:', pairingError.code);
    return Response.json({ error: 'Patient name is temporarily unavailable.' }, { status: 500, headers });
  }
  if (!pairing) {
    return Response.json({ error: 'No accepted pairing.' }, { status: 403, headers });
  }

  const { data: profile, error: profileError } = await admin
    .from('profiles')
    .select('name')
    .eq('id', patientId)
    .maybeSingle();
  if (profileError) {
    console.error('Patient name lookup failed:', profileError.code);
    return Response.json({ error: 'Patient name is temporarily unavailable.' }, { status: 500, headers });
  }

  return Response.json({ name: profile?.name?.trim() || null }, { headers });
});
