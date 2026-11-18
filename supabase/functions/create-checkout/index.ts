import { stripe, SITE_URL, TAX_ON, MANAGED_ON, admin, cors, json, userFrom } from '../_shared/common.ts';

// Throne Pass: $5.99/month subscription. Required to be ranked. Perks only, no cash prizes.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const user = await userFrom(req);
    if (!user) return json({ error: 'Sign in first.' }, 401);

    const { data: profile } = await admin.from('profiles').select('gamertag').eq('id', user.id).maybeSingle();
    if (!profile) return json({ error: 'Set up your player card first.' }, 400);

    const { data: mem } = await admin.from('memberships').select('*').eq('user_id', user.id).maybeSingle();
    const active = mem && ['active', 'trialing'].includes(mem.status) &&
      (!mem.current_period_end || new Date(mem.current_period_end) > new Date());
    if (active) return json({ error: 'You are already a member.' }, 409);

    let customer = mem?.stripe_customer_id as string | undefined;
    if (!customer) {
      // Idempotency key: a double-click can't create two Stripe customers for one player.
      const c = await stripe.customers.create(
        { email: user.email, metadata: { user_id: user.id, gamertag: profile.gamertag } },
        { idempotencyKey: `ty-customer-${user.id}` },
      );
      customer = c.id;
      await admin.from('memberships').upsert({ user_id: user.id, stripe_customer_id: customer, updated_at: new Date().toISOString() });
    }

    const session = await stripe.checkout.sessions.create({
      mode: 'subscription',
      customer,
      line_items: [{ price: Deno.env.get('STRIPE_PRICE_ID')!, quantity: 1 }],
      client_reference_id: user.id,
      subscription_data: { metadata: { user_id: user.id } },
      success_url: `${SITE_URL}/submit.html?pass=success`,
      cancel_url: `${SITE_URL}/submit.html?pass=cancel`,
      allow_promotion_codes: true,
      integration_identifier: 'throne-pass-qkmvrtzb',
      ...(MANAGED_ON ? { managed_payments: { enabled: true } } : TAX_ON ? {
        automatic_tax: { enabled: true },
        billing_address_collection: 'required',
        customer_update: { address: 'auto', name: 'auto' },
      } : {}),
    });
    return json({ url: session.url });
  } catch (e) {
    console.error(e);
    return json({ error: 'Checkout is unavailable right now. Try again in a minute.' }, 500);
  }
});
