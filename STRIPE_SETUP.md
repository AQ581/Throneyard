# Throneyard × Stripe — setup and plan

Products: **Payments** (Throne Pass, $5.99/month) and **Tax**, either Stripe Tax or Managed Payments. No Connect: Throneyard doesn't pay anyone out.
API version: `2026-10-28.endive` · Node/Deno library: `stripe@23.1.0`.

Never paste Stripe keys into a chat. Put them only in Supabase → Edge Functions → Secrets.

---

## Part 1 — Throne Pass (live in your code now)

### 1. Test first in a sandbox
Stripe Dashboard → account menu → **Sandboxes → Create**. Do steps 2–5 in the sandbox, run a test purchase with card `4242 4242 4242 4242`, then repeat in live mode.

### 2. Product and price
Product Catalog → **Add product**: "Throneyard Throne Pass", recurring **$5.99 / month**. Copy the price ID (`price_...`).

### 3. Restricted API key (instead of the full secret key)
Developers → API keys → **Create restricted key**, named "Throneyard edge functions":

| Resource | Permission |
|---|---|
| Checkout Sessions | Write |
| Customers | Write |
| Customer portal | Write |
| Subscriptions | Read |
| Invoices | Read |
| Charges (and Refunds/Disputes) | Read |
| Prices / Products | Read |

Everything else: None.

### 4. Webhook
Developers → Webhooks → **Add destination** → URL:
`https://niyjmljlsqbqniqvlktv.supabase.co/functions/v1/stripe-webhook`

Events (only these):
`checkout.session.completed`, `checkout.session.async_payment_succeeded`,
`customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`,
`invoice.paid`, `invoice.payment_failed`,
`charge.dispute.created`, `charge.refunded`, `radar.early_fraud_warning.created`

Copy the signing secret (`whsec_...`).

### 5. Supabase secrets (Edge Functions → Secrets)
| Name | Value |
|---|---|
| `STRIPE_SECRET_KEY` | the restricted key `rk_...` |
| `STRIPE_PRICE_ID` | `price_...` |
| `STRIPE_WEBHOOK_SECRET` | `whsec_...` |
| `SITE_URL` | `https://throneyard.com` |
| `STRIPE_AUTOMATIC_TAX` | leave unset until Part 2 is done, then `on` |

### 6. Customer portal
Settings → Billing → **Customer portal**: allow cancel and payment-method updates.

What the code already does:
- It grants the pass from the webhook, never the success page.
- It handles each Stripe event once, even if Stripe sends it twice.
- It re-syncs the pass on renewals, failed payments, refunds and disputes.
- It logs disputes, refunds and fraud warnings to `billing_alerts` for you to review.
- A double-click can't create two Stripe customers.

---

## Part 2 — Stripe Tax

Turning tax on without a registration collects **nothing, with no error**. So do these in order:

1. **Tax → Settings:** set your head office address (Mississauga, ON).
2. **Product tax code:** on the Throne Pass product, pick the code yourself from Stripe's list: https://docs.stripe.com/tax/tax-codes (digital products guide: https://docs.stripe.com/tax/digital-products). Avoid the generic "General – Electronically Supplied Services". Ask your accountant which fits a gaming membership.
3. **Registrations (Tax → Registrations):**
   - **Canada GST/HST:** register once you pass the $30,000 CAD small-supplier threshold, or earlier by choice. Ask your accountant.
   - **Other places:** Tax → Locations → *Needs attention* shows where foreign sales cross a threshold. US states, the EU and the UK tax digital services, and Stripe can register for you in some of them.
4. Set `STRIPE_AUTOMATIC_TAX=on` in Supabase secrets. Checkout then collects the buyer's address and adds the right tax.
5. **Check it:** make a sandbox test purchase with an Ontario address. Open the session in the Dashboard; the tax line should show HST, not "not collecting".

---

## Part 3 — Managed Payments (recommended instead of running tax yourself)

Throneyard only collects money (the $5.99 pass) and pays nobody out, so **Connect isn't needed**.

Stripe's planner recommended **Managed Payments** for you. Stripe becomes the seller of record: it calculates, collects, files and pays sales tax/VAT/GST in 80+ countries, and handles fraud and disputes. Canada is a supported location, and a fully automated digital membership qualifies.
- **Cost:** a 3.5% add-on, about $0.21 per $5.99 payment, on top of normal Stripe fees.
- **What it replaces:** Part 2. No GST/HST or EU VAT registrations or filings for these sales.
- **To turn it on:**
  1. Accept the terms at Dashboard → Settings → Managed Payments.
  2. Pick a product tax code labeled *Eligible for Managed Payments*.
  3. Set the Supabase secret `STRIPE_MANAGED_PAYMENTS=on`, and leave `STRIPE_AUTOMATIC_TAX` unset.
- **Limits:** it only applies to new subscriptions. Checkout uses Stripe's standard page, so no custom text. Stripe (through Link) sends receipts and gives buyers transaction support.

## Rankings require the Throne Pass
- Only active members appear on global, country, city and continental boards, and only members win monthly badges or World Final seats.
- Free players' verified runs are saved and count the moment they subscribe. They drop off the boards when the pass is cancelled or runs out (checked every 15 minutes).
