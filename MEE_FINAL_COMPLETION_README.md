# MEE — Final Completion Work Package (V1)

This package is based on the user-provided `MEE_Login_Message_Removed.zip` source. Existing branding, routes, authentication and the original Supabase model are retained.

## Changes included in this package

### 1. Customer account and ledger
- Payment receipt can be posted against a selected final invoice or as an unallocated customer-account credit.
- Receipt store can be selected, rather than silently forcing the current active store.
- Manual customer ledger adjustment is available: debit increases outstanding; credit reduces outstanding.
- Opening customer balances are backfilled idempotently by the new migration.
- Payment RPC validates the store, customer-business relationship, invoice-store relationship, invoice-customer relationship, final invoice status and remaining balance.
- UPI receipts require an explicit cashier verification confirmation in the UI and RPC.

### 2. Supplier account and ledger
- Supplier page now includes purchase history, supplier payable summary, ledger and payment receipt form.
- Supplier opening balances entered through the supplier form are posted to the supplier ledger.
- Existing non-zero supplier opening balances are backfilled to the first store of the business, if no opening entry exists.
- UPI supplier payments require explicit verification in the UI and RPC.

### 3. Inventory operations
- New `/inventory` page is linked in the navigation.
- Current stock, reorder threshold, estimated stock cost value and recent movements are displayed per selected store.
- Manual stock adjustments require a reason and are posted through a transactional RPC with inventory movement and audit log.
- Inter-store stock transfer is atomic. Source and destination stores must be in the same business, the user must have management permission for both stores, and destination product must have the same active SKU.
- Product opening stock now uses the stock-adjustment RPC rather than two independent direct inserts.

### 4. Data integrity and safety
- Financial, customer and supplier records are no longer hard-deleted from the generic module list. Product records use archive/inactive instead of destructive delete.
- Added indexes for customer ledger, customer invoice history and inventory movement history.
- `.gitignore` now excludes all `.env*` files except `.env.example`.
- Existing login developer guidance remains removed.

## Migration

New migration:

`supabase/migrations/20261101000100_mee_financial_and_inventory_hardening.sql`

For a project that already has all migrations through `20261027000200`, apply only this new migration once in Supabase SQL Editor. For a fresh Supabase project, apply every migration in `supabase/migrations` in filename order.

The migration is transactional. Review it and take a database backup before applying it to production. Do not paste a service-role key into SQL or frontend code.

## Environment setup

Copy `.env.example` to `.env.local` and enter the real values:

- `NEXT_PUBLIC_SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_ANON_KEY` (or publishable key accepted by the installed supabase-js client)
- `SUPABASE_SERVICE_ROLE_KEY` (server only; needed for username lookup and admin creation)

Never commit `.env.local` or any production secret.

## Local build commands

```powershell
npm ci
npm run build
npm run start
```

## Required production acceptance tests

The package has not been certified against a live Supabase database or a production Vercel deployment. Before calling the system production-ready, test with real accounts and sample records:

1. Super Admin can see and manage all three stores; Store Admin can only access assigned store(s).
2. Final cash, UPI-verified, card, bank-transfer, partial and credit invoices produce correct payment, stock and customer-ledger entries.
3. Customer receipt applied to an invoice updates invoice amount-paid, balance-due and payment status; unallocated receipt affects customer account ledger only.
4. Cross-business customer IDs and cross-store invoice payment attempts are rejected by RPC.
5. Customer manual debit/credit adjustments create audit log entries and correct running balance.
6. Purchase receipt increases stock and supplier payable atomically; supplier payments reduce supplier payable.
7. Stock adjustment rejects zero quantity, blank reason and negative resulting stock.
8. Stock transfer rejects insufficient stock, missing destination SKU, same-store transfer and unauthorized destination store; successful transfer changes both balances and creates both movements.
9. RLS tests verify that Store Admin cannot read another store's customer ledger, inventory, supplier ledger, invoices or movements.
10. Restore from backup and verify historical invoices, purchases, payments and ledgers.

## Known scope not certified / still requires implementation or E2E proof

This is a substantial operational hardening release, not a claim that every enterprise feature is finished. The following still need dedicated workflows and tests before a fully certified ERP release:

- Sales returns, purchase returns, refunds, credit notes, invoice void/reversal and allocation of old unallocated receipts.
- Physical stock-count sessions, batch/serial/expiry tracking and purchase/sales return inventory lifecycle.
- Cash drawer opening/closing, cash handover, bank reconciliation and accounting journal/financial statements.
- Supplier payment allocation to individual purchase invoices and supplier credit-note/return lifecycle.
- Customer/supplier ageing reports, true COGS-based gross profit, GST return reconciliation and period locking.
- Online order fulfilment, delivery assignment, refund workflow and payment gateway verification/webhooks.
- Backup automation, disaster recovery drills, monitoring, rate limiting and full security/performance review.
- Full Next.js production build, live Supabase migration execution, RLS tests and end-to-end tests on all three stores.

Do not represent these unverified workflows as production-ready until their acceptance tests pass.


## Developer-only data maintenance (2026-11-02)
- Hidden route: `/dev/mee-control` (not listed in the sidebar).
- Requires a verified MEE `super_admin` session plus server-only `MEE_DEVELOPER_RESET_KEY`.
- Includes a record preview, selectable cleanup groups, a browser confirmation dialog, and a server-side transactional reset RPC. No backup download or typed confirmation phrase is required.
- Migration: `supabase/migrations/20261102000100_mee_developer_data_reset.sql`. Apply this migration before attempting a reset.
- Preserves the business master, exactly three store rows/IDs, storefront settings/public slugs, Auth accounts, profiles, business memberships and store memberships. Store active/inactive states are unchanged.
- See `DEVELOPER_DATA_RESET.md` for deployment and operational instructions.
- This ZIP does not execute the migration or delete any live Supabase data.
