const pageHeaders = {
  'Content-Type': 'text/html; charset=utf-8',
  'Cache-Control': 'no-store',
};

Deno.serve((request) => {
  if (request.method !== 'GET') {
    return new Response('Method not allowed.', { status: 405 });
  }

  const url = new URL(request.url);
  const pairingId = url.searchParams.get('pairing_id')?.trim() ?? '';
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(pairingId)) {
    return new Response('This invitation link is not valid.', {
      status: 400,
      headers: pageHeaders,
    });
  }

  const appLink = `medisense://pairing/invitation?pairing_id=${encodeURIComponent(pairingId)}`;
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#53694B"><title>MediSense invitation</title><style>body{margin:0;padding:24px;min-height:100vh;box-sizing:border-box;display:grid;place-items:center;background:#F7F6F2;color:#282A25;font-family:Arial,Helvetica,sans-serif}.card{width:min(100%,480px);box-sizing:border-box;padding:32px;background:#fff;border:1px solid #DED8CF;border-radius:22px}.brand{margin:0;color:#30352D;font-size:24px;font-weight:700}.eyebrow{margin:6px 0 28px;color:#747468;font-size:11px;letter-spacing:1.4px}.tag{color:#53694B;font-size:11px;font-weight:700;letter-spacing:1.4px}h1{font-size:25px;line-height:1.25;margin:12px 0}p{font-size:16px;line-height:1.55;color:#54544C}.button{display:block;margin:24px 0 16px;padding:16px 20px;border-radius:12px;background:#53694B;color:#fff;text-align:center;text-decoration:none;font-weight:700;font-size:16px;min-height:24px}.hint{font-size:14px;color:#67685F}</style></head><body><main class="card"><p class="brand">MediSense</p><p class="eyebrow">YOUR MEDICATION COMPANION</p><p class="tag">GUARDIAN INVITATION</p><h1>Review your pairing request</h1><p>Open MediSense to review the invitation. Your medication information is shared only if you sign in as the invited patient and accept.</p><a class="button" href="${appLink}">Open MediSense</a><p class="hint">If nothing happens, install or open the MediSense app, sign in with the invited patient account, then open <strong>Guardian → Pending Requests</strong>.</p></main></body></html>`;
  return new Response(html, { status: 200, headers: pageHeaders });
});
