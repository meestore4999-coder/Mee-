# MEE build fixes — 2026-10-27

Applied fixes based on the latest Windows `npm run build` output:

1. `lib/mee-context.tsx`: Store type explicitly includes address, phone, email, GSTIN and settings fields used by BillingWorkspace.
2. `components/CustomerLedgerPanel.tsx`: running-balance ledger rows are explicitly typed as `AnyRow[]`, preventing TypeScript from narrowing mapped rows to `{ running: number }` and rejecting `x.id`.
3. Preserved the earlier `Settings` query fix and `resolve-login` user metadata typing fix from the prior build-audit ZIP.

Archive integrity is checked. A fresh Next.js production build has not been run in this environment because node_modules are not present here.
