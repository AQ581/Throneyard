import Stripe from 'npm:stripe@23.1.0';
import { stripe, admin } from '../_shared/common.ts';

const secret = Deno.env.get('STRIPE_WEBHOOK_SECRET') ?? '';
const crypto = Stripe.createSubtleCryptoProvider();
const idOf = (x: unknown) => (typeof x === 'string' ? x : (x as { id?: string } | null)?.id ?? null);

// Keep the player's membership row in step with their Stripe subscription.
async function sync(sub: Stripe.Subscription, userId?: string | null) {
  const customer = idOf(sub.customer)!;
  let uid = userId ?? null;
  if (!uid) {
    const { data } = await admin.from('memberships').select('user_id').eq('stripe_customer_id', customer).maybeSingle();
    uid = data?.user_id ?? (sub.metadata?.user_id as string | undefined) ?? null;
  }
  if (!uid) { console.warn('No user for customer', customer); return; }
  // deno-lint-ignore no-explicit-any
  const s = sub as any;
  const end = s.items?.data?.[0]?.current_period_end ?? s.current_period_end ?? null;
  const { error } = await admin.from('memberships').upsert({
    user_id: uid,
    stripe_customer_id: customer,
    stripe_subscription_id: sub.id,
    status: sub.status,
    current_period_end: end ? new Date(end * 1000).toISOString() : null,
    updated_at: new Date().toISOString(),
  });
  if (error) throw error;
}

// Invoices point at their subscription through invoice.parent on current API versions.
function subscriptionOfInvoice(inv: Stripe.Invoice): string | null {
  // deno-lint-ignore no-explicit-any
  const i = inv as any;
  return idOf(i.parent?.subscription_details?.subscription) ?? idOf(i.subscription);
}

async function resyncFromInvoice(invoiceId: string | null) {
  if (!invoiceId) return;
  const inv = await stripe.invoices.retrieve(invoiceId);
  const subId = subscriptionOfInvoice(inv);
  if (subId) await sync(await stripe.subscriptions.retrieve(subId));
}

// Disputes, refunds and fraud warnings: find the player by Stripe customer, re-sync their pass, flag it for the admin.
async function riskEvent(kind: string, chargeId: string | null, event: Stripe.Event) {
  let customer: string | null = null;
  let subId: string | null = null;
  if (chargeId) customer = idOf((await stripe.charges.retrieve(chargeId)).customer);
  if (customer) {
    const { data } = await admin.from('memberships').select('stripe_subscription_id').eq('stripe_customer_id', customer).maybeSingle();
    subId = data?.stripe_subscription_id ?? null;
    if (subId) await sync(await stripe.subscriptions.retrieve(subId));
  }
  await admin.from('billing_alerts').insert({ kind, stripe_event_id: event.id, stripe_customer_id: customer, stripe_subscription_id: subId, charge_id: chargeId });
}

Deno.serve(async (req) => {
  const sig = req.headers.get('stripe-signature');
  if (!sig) return new Response('Missing signature', { status: 400 });
  const body = await req.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, sig, secret, undefined, crypto);
  } catch (e) {
    console.error('Bad signature', e);
    return new Response('Bad signature', { status: 400 });
  }
  // Stripe can deliver the same event more than once; handle each one once.
  const { error: dup } = await admin.from('stripe_events').insert({ id: event.id, type: event.type });
  if (dup) {
    if (dup.code === '23505') return new Response(JSON.stringify({ received: true, duplicate: true }), { headers: { 'Content-Type': 'application/json' } });
    console.error(dup);
  }
  try {
    switch (event.type) {
      case 'checkout.session.completed':
      case 'checkout.session.async_payment_succeeded': {
        const session = event.data.object as Stripe.Checkout.Session;
        if (session.mode === 'subscription' && session.subscription && session.payment_status !== 'unpaid') {
          await sync(await stripe.subscriptions.retrieve(idOf(session.subscription)!), session.client_reference_id);
        }
        break;
      }
      case 'customer.subscription.created':
      case 'customer.subscription.updated':
      case 'customer.subscription.deleted':
        await sync(event.data.object as Stripe.Subscription);
        break;
      case 'invoice.paid':
      case 'invoice.payment_failed':
        await resyncFromInvoice((event.data.object as Stripe.Invoice).id ?? null);
        break;
      case 'charge.dispute.created':
        await riskEvent('dispute', idOf((event.data.object as Stripe.Dispute).charge), event);
        break;
      case 'charge.refunded':
        await riskEvent('refund', (event.data.object as Stripe.Charge).id, event);
        break;
      case 'radar.early_fraud_warning.created':
        await riskEvent('fraud_warning', idOf((event.data.object as Stripe.Radar.EarlyFraudWarning).charge), event);
        break;
    }
    return new Response(JSON.stringify({ received: true }), { headers: { 'Content-Type': 'application/json' } });
  } catch (e) {
    console.error('Webhook handling failed', e);
    // Let Stripe retry: forget this event so the retry is processed.
    await admin.from('stripe_events').delete().eq('id', event.id);
    return new Response('Webhook error', { status: 500 });
  }
});
