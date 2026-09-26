// Supabase's shared domain serves HTML from Edge Functions as plain text.
// Redirect the checkout browser without returning an HTML page.
const APP_DEEP_LINK = 'medisense://payment/success';

Deno.serve((req) => {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return new Response('Method not allowed', {
      status: 405,
      headers: { Allow: 'GET, HEAD' },
    });
  }

  return new Response(null, {
    status: 302,
    headers: {
      Location: APP_DEEP_LINK,
      'Cache-Control': 'no-store, max-age=0',
    },
  });
});
