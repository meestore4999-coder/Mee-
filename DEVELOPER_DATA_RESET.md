# MEE Developer Data Maintenance

## Hidden panel
- Route: `/dev/mee-control` (intentionally not added to the sidebar/navigation).
- Requires a signed-in MEE `super_admin` membership AND a server-only developer key.
- The developer key is checked by the server using constant-time comparison.
- Normal store admins cannot use the endpoint, even if they discover the URL.

## Server environment
Set both existing Supabase server credentials and a separate developer secret:
- `SUPABASE_SERVICE_ROLE_KEY` — Supabase service-role key; server only.
- `MEE_DEVELOPER_RESET_KEY` — random secret, minimum 24 characters; server only.
Do not use `NEXT_PUBLIC_` for either value. Do not commit real secrets to Git.
Configure these in `.env.local` and the hosting provider's server environment, then restart/redeploy.

## Required database migration
Apply `supabase/migrations/20261102000100_mee_developer_data_reset.sql` to the connected MEE Supabase project before using reset. The migration creates a transaction-safe function restricted to `service_role`. It refuses to run unless exactly three stores exist for the signed-in Super Admin's business.

## Reset workflow
1. Sign in using the MEE Super Admin account.
2. Open `/dev/mee-control`.
3. Enter the server-side developer key and load the preview.
4. Download and safely retain the JSON backup.
5. Type exactly `RESET MEE OPERATIONAL DATA`.
6. Confirm the browser warning and run the reset.

Choose one or more cleanup groups in the panel: catalog/inventory; sales/customers; purchasing/suppliers; expenses; marketing banners/offers; audit logs. The SQL function performs the selected deletions in a single PostgreSQL transaction and preserves unselected groups. Foreign-key dependencies are handled by the selected group workflow.

It preserves the business row, all three store rows and IDs, storefront settings/public slugs, Auth users (login accounts), profiles, business memberships and store memberships. It does not change the active/inactive state of any store.

The reset function is transactional: if a required delete fails, PostgreSQL rolls the whole operation back. The UI selects all cleanup groups by default, but individual groups can be unchecked. The JSON backup includes operational rows and a safe metadata snapshot of protected records; it does not include passwords, password hashes, or secret keys.

## Safety notes
- The panel is hidden from navigation, but URL secrecy is not treated as authorization.
- Do not expose the developer key in browser source, client-side environment variables, screenshots, or Git.
- Test on a non-production clone before customer handover.
- The migration is not auto-applied by the app. A database owner must apply it deliberately.
