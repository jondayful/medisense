export const plans: Record<string, {
  amount: number;
  name: string;
  tier: string;
  durationDays: number;
}> = {
  premium_monthly: {
    amount: 9900,
    name: 'MediSense Premium - 1 month',
    tier: 'Premium',
    durationDays: 31,
  },
  guardian_annual: {
    amount: 59900,
    name: 'MediSense Annual Cloud OCR - 1 year',
    tier: 'Guardian',
    durationDays: 365,
  },
};

export function paymongoAuth(secret: string) {
  return `Basic ${btoa(`${secret}:`)}`;
}

export function findReference(value: unknown): string | null {
  if (!value || typeof value !== 'object') return null;
  for (const [key, child] of Object.entries(value as Record<string, unknown>)) {
    if (
      ['reference_number', 'external_reference_number', 'referenceNumber'].includes(key) &&
      typeof child === 'string' && child.startsWith('medisense_')
    ) return child;
    const nested = findReference(child);
    if (nested) return nested;
  }
  return null;
}

export function constantTimeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return result === 0;
}

export async function hmacSha256(secret: string, value: string) {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(value));
  return Array.from(new Uint8Array(signature)).map((b) => b.toString(16).padStart(2, '0')).join('');
}
