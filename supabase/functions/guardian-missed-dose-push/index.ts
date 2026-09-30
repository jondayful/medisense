import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.95.0';
import { dueDoses, type CloudMedication, type CloudLog } from './due_doses.ts';

type Row = Record<string, unknown>;
type ServiceAccount = { project_id: string; client_email: string; private_key: string };

function base64url(bytes: Uint8Array) {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function firebaseAccessToken(account: ServiceAccount) {
  const pem = account.private_key.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, '');
  const keyBytes = Uint8Array.from(atob(pem), (char) => char.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', keyBytes, {
    name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256',
  }, false, ['sign']);
  const issuedAt = Math.floor(Date.now() / 1000);
  const encoder = new TextEncoder();
  const header = base64url(encoder.encode(JSON.stringify({ alg: 'RS256', typ: 'JWT' })));
  const payload = base64url(encoder.encode(JSON.stringify({
    iss: account.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: issuedAt,
    exp: issuedAt + 3600,
  })));
  const assertion = `${header}.${payload}`;
  const signature = base64url(new Uint8Array(await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5', key, encoder.encode(assertion),
  )));
  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${assertion}.${signature}`,
    }),
  });
  if (!response.ok) throw new Error(`Firebase OAuth failed: ${response.status}`);
  const body = await response.json();
  if (typeof body.access_token !== 'string') throw new Error('Firebase OAuth returned no token');
  return body.access_token as string;
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return Response.json({ error: 'Method not allowed' }, { status: 405 });
  const cronSecret = Deno.env.get('GUARDIAN_PUSH_CRON_SECRET');
  if (!cronSecret || request.headers.get('x-cron-secret') !== cronSecret) {
    return Response.json({ error: 'Unauthorized' }, { status: 401 });
  }
  const url = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const rawFirebase = Deno.env.get('FIREBASE_SERVICE_ACCOUNT_JSON');
  if (!url || !serviceKey || !rawFirebase) {
    return Response.json({ error: 'Push service is not configured' }, { status: 503 });
  }
  try {
    const account = JSON.parse(rawFirebase) as ServiceAccount;
    if (!account.project_id || !account.client_email || !account.private_key) {
      throw new Error('Firebase service account is incomplete');
    }
    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    async function readAll(table: string, columns: string, order: string,
      filter?: { column: string; value: string }): Promise<Row[]> {
      const rows: Row[] = [];
      for (let start = 0; ; start += 500) {
        let query = admin.from(table).select(columns);
        if (filter) query = query.eq(filter.column, filter.value);
        const { data, error } = await query.order(order).range(start, start + 499);
        if (error) throw new Error(`${table} read failed: ${error.message}`);
        rows.push(...(data ?? []) as Row[]);
        if (!data || data.length < 500) break;
      }
      return rows;
    }
    const tokens = await readAll('guardian_push_tokens', 'token, guardian_id', 'token');
    if (tokens.length === 0) return Response.json({ sent: 0, eligible: 0 });
    const tokensByGuardian = new Map<string, string[]>();
    for (const row of tokens) {
      const guardianId = row.guardian_id as string;
      const token = row.token as string;
      tokensByGuardian.set(guardianId, [...(tokensByGuardian.get(guardianId) ?? []), token]);
    }
    const pairings = (await readAll('pairings', 'id, guardian_id, patient_id, status', 'id',
      { column: 'status', value: 'accepted' }))
      .filter((row) => tokensByGuardian.has(row.guardian_id as string));
    const byPatient = new Map<string, string[]>();
    for (const row of pairings) {
      const patientId = row.patient_id as string;
      byPatient.set(patientId, [...(byPatient.get(patientId) ?? []), row.guardian_id as string]);
    }
    if (byPatient.size === 0) return Response.json({ sent: 0, eligible: 0 });
    const accessToken = await firebaseAccessToken(account);
    const now = new Date();
    let eligible = 0;
    let sent = 0;
    for (const [patientId, guardianIds] of byPatient) {
      const { data: profile, error: profileError } = await admin.from('profiles')
        .select('time_zone').eq('id', patientId).maybeSingle();
      if (profileError) throw profileError;
      const zone = profile?.time_zone;
      if (typeof zone !== 'string' || !zone) continue;
      const medications = await readAll('medications', 'id, data', 'id',
        { column: 'patient_id', value: patientId });
      // Logs can be updated long after their original insert, so created_at
      // cannot safely bound this read without missing a newly taken dose.
      const logs = await readAll('adherence_logs', 'id, data', 'id',
        { column: 'patient_id', value: patientId });
      let doses;
      try {
        doses = dueDoses(medications as CloudMedication[], logs as CloudLog[], zone, now);
      } catch (error) {
        console.error('Invalid patient time zone:', error);
        continue;
      }
      for (const guardianId of guardianIds) {
        for (const dose of doses) {
          const { data: stillPaired, error: pairingError } = await admin.from('pairings')
            .select('id').eq('guardian_id', guardianId)
            .eq('patient_id', patientId).eq('status', 'accepted').limit(1);
          if (pairingError) throw pairingError;
          if (!stillPaired?.length) continue;
          eligible++;
          const params = {
            p_guardian_id: guardianId, p_patient_id: patientId,
            p_medication_id: dose.medicationId,
            p_schedule_id: dose.scheduleId, p_dose_day: dose.doseDay,
          };
          const { data: claimed, error: claimError } = await admin.rpc('claim_missed_dose_push', params);
          if (claimError) throw claimError;
          if (claimed !== true) continue;
          let anyDelivered = false;
          for (const token of tokensByGuardian.get(guardianId) ?? []) {
            try {
              const response = await fetch(
                `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(account.project_id)}/messages:send`,
                {
                  method: 'POST',
                  headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
                  body: JSON.stringify({ message: {
                    token,
                    notification: {
                      title: 'Scheduled dose not recorded',
                      body: 'Open MediSense to check with the patient.',
                    },
                    data: { route: 'guardian', patientId },
                    android: { priority: 'high' },
                    apns: { payload: { aps: { sound: 'default' } } },
                  } }),
                },
              );
              if (response.ok) {
                anyDelivered = true;
                sent++;
              } else {
                const body = await response.json().catch(() => ({}));
                const errorCode = body?.error?.details?.find?.(
                  (entry: { errorCode?: string }) => entry.errorCode,
                )?.errorCode;
                console.error('FCM send failed:', response.status, errorCode ?? body?.error?.status);
                if (errorCode === 'UNREGISTERED') {
                  await admin.from('guardian_push_tokens').delete().eq('token', token);
                }
              }
            } catch (error) {
              console.error('FCM connection failed:', error);
            }
          }
          if (anyDelivered) {
            const { error: markError } = await admin.rpc('mark_missed_dose_push_sent', params);
            if (markError) throw markError;
          }
        }
      }
    }
    return Response.json({ sent, eligible });
  } catch (error) {
    console.error('Guardian missed-dose push job failed:', error);
    return Response.json({ error: 'Push job failed' }, { status: 500 });
  }
});
