import { stripe, SITE_URL, admin, cors, json, userFrom } from '../_shared/common.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const user = await userFrom(req);
    if (!user) return json({ error: 'Sign in first.' }, 401);
    const { data: mem } = await admin.from('memberships').select('stripe_customer_id').eq('user_id', user.id).maybeSingle();
    if (!mem?.stripe_customer_id) return json({ error: 'No pass found on this account.' }, 404);
    const portal = await stripe.billingPortal.sessions.create({
      customer: mem.stripe_customer_id,
      return_url: `${SITE_URL}/submit.html`,
    });
    return json({ url: portal.url });
  } catch (e) {
    console.error(e);
    return json({ error: 'Billing is unavailable right now.' }, 500);
  }
});
