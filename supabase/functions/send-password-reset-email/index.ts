import { corsHeaders } from '../_shared/cors.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405, headers: corsHeaders });
  const { toEmail, code } = await req.json();
  const apiKey = Deno.env.get('MAILERSEND_API_KEY');
  if (!apiKey || typeof toEmail !== 'string' || typeof code !== 'string') {
    return Response.json({ error: 'Invalid request' }, { status: 400, headers: corsHeaders });
  }
  const response = await fetch('https://api.mailersend.com/v1/email', {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: { email: Deno.env.get('MAILERSEND_FROM_EMAIL') || 'noreply@example.com', name: 'MediSense' },
      to: [{ email: toEmail }],
      subject: 'MediSense - Password Reset Code',
      html: `<p>Your MediSense password reset code is <strong>${code}</strong>.</p><p>This code expires in 10 minutes.</p>`,
    }),
  });
  return new Response(JSON.stringify({ ok: response.ok }), { status: response.ok ? 200 : 502, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
});
