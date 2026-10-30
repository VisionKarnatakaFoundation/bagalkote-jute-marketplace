# Bagalkote Jute Artisans Marketplace

VKF-facilitated jute marketplace with Supabase authentication, seller moderation,
product photos and stock, private orders, manual payment verification and dispatch.

## Current deployment

- Source: VisionKarnatakaFoundation/bagalkote-jute-marketplace
- Supabase project: `nlrfgaovwnawprgjepds` (Mumbai region)
- Static files: `index.html`, `app.js`, `config.js`
- Client SDK pinned to `@supabase/supabase-js@2.118.0`.
- `config.js` contains only a public publishable key; never add a secret or service-role key.
- The original 16 catalogue photos remain illustrative, non-orderable examples.
  Approved sellers must add actual listings with confirmed prices and stock.

## Required before public registration

In this project's Supabase dashboard:

1. Authentication → URL Configuration: set the Site URL and allowed redirect URL
   to the actual deployed website URL, including its repository subpath.
2. Configure custom SMTP for confirmation and password-reset emails. The built-in
   sender is limited to organisation team addresses. Keep Confirm Email enabled.
3. Test registration, email confirmation and password reset from a non-team address.
4. Register and verify the intended administrator account, then assign its role
   through trusted database administration, not a public registration control.
   Match the verified user's ID and email before running the role update:

   ```sql
   select p.id,u.email,u.email_confirmed_at,p.role
   from public.bj_profiles p join auth.users u on u.id=p.id;
   -- After checking the intended verified user:
   -- update public.bj_profiles set role='admin' where id='<verified-user-id>';
   ```

No admin has been automatically assigned. Public signup can create only customer
or seller profiles. A customer can later submit a seller application.

## Order workflow

Request → seller confirms shipping and payment instructions → 48-hour reservation
→ buyer submits transaction reference and exact total → seller checks their own
bank/payment account → seller approves → stock decreases → dispatch → buyer confirms receipt.

- One product and seller per order. No online payment gateway or escrow.
- Expired unpaid quotes cannot accept payment references; the seller can renew them.
- Payment-submitted stock stays reserved pending seller review.
- Cancelling an unpaid order releases its reservation.
- Paid orders cannot be silently cancelled/refunded through the app. The seller and
  VKF must resolve disputes/refunds directly; a refund automation is not implemented.
- Seller suspension hides listings immediately and blocks new sales. Historical
  orders remain readable, and existing paid orders can still be fulfilled.
- Admin can review paginated orders and export all recorded orders to CSV.
- Product photos are public; delivery addresses and payment references are private
  to the buyer, seller and admin. Product uploads are immutable, maximum 1 MB.
- No payment screenshots, automated WhatsApp messages, bank verification, Google
  Sheets sync or automated email order notifications are implemented.

## Security and validation

`backend/schema.sql` is the schema snapshot deployed to the new project using a
Supabase migration. All public tables have row-level security and no client write
grants. Checked transactional RPCs control mutations and lock product rows before
order rows. Inventory and payment checks are enforced in Postgres, not just the UI.
Admin roles cannot be set through user-editable signup metadata.

`tests/access_inventory.sql` runs in a rolled-back transaction with synthetic users.
It checks metadata escalation, seller approval, direct writes, private order reads,
stock reservations, overselling, buyer self-verification, duplicate approval,
dispatch, receipt and seller suspension. No fixture data remains afterward.

Supabase security advisors reported no findings after deployment. Browser checks
covered the catalogue, images and role-selection forms; public email delivery and
a complete browser purchase require the email configuration and real accounts.

## Operations

Monitor Supabase free-tier storage and egress. Low-activity free projects can pause.
Export records regularly; do not treat CSV exports as a full database/photo backup.
GitHub can retain the source. Move transactional hosting away from GitHub Pages
before a sustained public launch, per its hosting limits.
