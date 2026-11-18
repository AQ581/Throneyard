import Stripe from 'npm:stripe@23.1.0';
import { createClient } from 'npm:@supabase/supabase-js@2';

// Use a restricted key (rk_...) with only the permissions listed in STRIPE_SETUP.md.
export const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? '', {
  apiVersion: '2026-10-28.endive',
  httpClient: Stripe.createFetchHttpClient(),
});
// Turn on only after Stripe Tax has a head office address AND an active registration (see STRIPE_SETUP.md).
export const TAX_ON = (Deno.env.get('STRIPE_AUTOMATIC_TAX') ?? '').toLowerCase() === 'on';
// Managed Payments: Stripe is merchant of record and handles tax worldwide. Takes priority over TAX_ON.
export const MANAGED_ON = (Deno.env.get('STRIPE_MANAGED_PAYMENTS') ?? '').toLowerCase() === 'on';
export const SITE_URL = (Deno.env.get('SITE_URL') ?? 'https://throneyard.com').replace(/\/$/, '');
export const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
});
export const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

export async function userFrom(req: Request) {
  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
  if (!token) return null;
  const { data } = await admin.auth.getUser(token);
  return data.user ?? null;
}
