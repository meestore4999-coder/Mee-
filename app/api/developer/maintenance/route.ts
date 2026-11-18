import { NextResponse } from 'next/server';
import { createClient, SupabaseClient } from '@supabase/supabase-js';
import { timingSafeEqual } from 'node:crypto';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const TABLES = [
  'products','categories','product_variants','inventory_balances','inventory_movements',
  'customers','suppliers','invoices','invoice_items','payments','customer_ledger_entries',
  'purchase_invoices','purchase_items','supplier_ledger_entries','expenses',
  'customer_orders','customer_order_items','store_banners','store_offers','audit_logs',
] as const;
const RESET_PHRASE = 'RESET MEE OPERATIONAL DATA';

function safeEqual(a: string, b: string) {
  const aa = Buffer.from(a); const bb = Buffer.from(b);
  return aa.length === bb.length && timingSafeEqual(aa, bb);
}
async function authorize(request: Request): Promise<{ admin: SupabaseClient; userId: string; businessId: string } | NextResponse> {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  const service = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const developerKey = process.env.MEE_DEVELOPER_RESET_KEY;
  if (!url || !anon || !service || !developerKey || developerKey.length < 24 ||
      /PLACEHOLDER|YOUR_|PASTE_SERVER_ONLY/i.test(service + developerKey)) {
    return NextResponse.json({ error: 'Developer reset is not configured. Set server-only SUPABASE_SERVICE_ROLE_KEY and MEE_DEVELOPER_RESET_KEY (24+ characters).' }, { status: 503 });
  }
  const suppliedKey = request.headers.get('x-mee-developer-key') || '';
  if (!safeEqual(suppliedKey, developerKey)) return NextResponse.json({ error: 'Developer authorization failed.' }, { status: 403 });
  const token = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token) return NextResponse.json({ error: 'Please sign in first.' }, { status: 401 });
  const authClient = createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: auth, error: authError } = await authClient.auth.getUser(token);
  if (authError || !auth.user) return NextResponse.json({ error: 'Session invalid. Sign in again.' }, { status: 401 });
  const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: memberships, error } = await admin.from('business_members')
    .select('business_id,role').eq('user_id', auth.user.id);
  if (error) return NextResponse.json({ error: 'Could not verify MEE role.' }, { status: 500 });
  const membership = (memberships || []).find((m: any) => m.role === 'super_admin');
  if (!membership) return NextResponse.json({ error: 'MEE Super Admin role required.' }, { status: 403 });
  const { count } = await admin.from('stores').select('id', { count: 'exact', head: true }).eq('business_id', membership.business_id);
  if (count !== 3) return NextResponse.json({ error: `Safety lock: exactly 3 stores required; found ${count ?? 0}.` }, { status: 409 });
  return { admin, userId: auth.user.id, businessId: membership.business_id };
}

async function getIds(admin: SupabaseClient, table: string, column: string, value: string) {
  const { data, error } = await admin.from(table).select('id').eq(column, value);
  if (error) throw new Error(`${table}: ${error.message}`);
  return (data || []).map((r: any) => r.id).filter(Boolean);
}
async function readRows(admin: SupabaseClient, table: string, apply: (q: any) => any) {
  const rows: any[] = [];
  for (let start = 0; ; start += 1000) {
    let q = admin.from(table).select('*');
    q = apply(q);
    const { data, error } = await q.range(start, start + 999);
    if (error) {
      if (['PGRST205', '42P01'].includes(error.code || '')) return null;
      throw new Error(`${table}: ${error.message}`);
    }
    rows.push(...(data || []));
    if (!data || data.length < 1000) break;
  }
  return rows;
}
async function collectSnapshot(admin: SupabaseClient, businessId: string) {
  const storeIds = await getIds(admin, 'stores', 'business_id', businessId);
  const invoiceIds = await getIds(admin, 'invoices', 'business_id', businessId);
  const purchaseIds = await getIds(admin, 'purchase_invoices', 'business_id', businessId);
  const orderIds = await getIds(admin, 'customer_orders', 'business_id', businessId);
  const productIds = await getIds(admin, 'products', 'store_id', storeIds[0] || '00000000-0000-0000-0000-000000000000').then(async first => {
    const all: string[] = [...first];
    for (const id of storeIds.slice(1)) all.push(...await getIds(admin, 'products', 'store_id', id));
    return all;
  });
  const specs: Record<string, (q: any) => any> = {
    products: q => q.in('store_id', storeIds),
    categories: q => q.in('store_id', storeIds),
    product_variants: q => q.in('product_id', productIds),
    inventory_balances: q => q.in('store_id', storeIds),
    inventory_movements: q => q.in('store_id', storeIds),
    customers: q => q.eq('business_id', businessId),
    suppliers: q => q.eq('business_id', businessId),
    invoices: q => q.eq('business_id', businessId),
    invoice_items: q => q.in('invoice_id', invoiceIds),
    payments: q => q.eq('business_id', businessId),
    customer_ledger_entries: q => q.eq('business_id', businessId),
    purchase_invoices: q => q.eq('business_id', businessId),
    purchase_items: q => q.in('purchase_invoice_id', purchaseIds),
    supplier_ledger_entries: q => q.eq('business_id', businessId),
    expenses: q => q.eq('business_id', businessId),
    customer_orders: q => q.eq('business_id', businessId),
    customer_order_items: q => q.in('order_id', orderIds),
    store_banners: q => q.in('store_id', storeIds),
    store_offers: q => q.in('store_id', storeIds),
    audit_logs: q => q.eq('business_id', businessId),
  };
  const snapshot: Record<string, any[] | null> = {};
  for (const table of TABLES) snapshot[table] = await readRows(admin, table, specs[table]);
  const business = await readRows(admin, 'businesses', q => q.eq('id', businessId));
  const stores = await readRows(admin, 'stores', q => q.eq('business_id', businessId));
  const storefrontSettings = await readRows(admin, 'storefront_settings', q => q.in('store_id', storeIds));
  const businessMembers = await readRows(admin, 'business_members', q => q.eq('business_id', businessId));
  const memberIds = (businessMembers || []).map((m: any) => m.user_id).filter(Boolean);
  const profiles = memberIds.length ? await readRows(admin, 'profiles', q => q.in('id', memberIds)) : [];
  const storeMembers = await readRows(admin, 'store_members', q => q.in('store_id', storeIds));
  const authUsers = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
  if (authUsers.error) throw new Error(`Auth user lookup: ${authUsers.error.message}`);
  const memberSet = new Set(memberIds);
  const authUserRecords = authUsers.data.users.filter((u: any) => memberSet.has(u.id)).map((u: any) => ({
    id: u.id, email: u.email || null, phone: u.phone || null, created_at: u.created_at,
    confirmed_at: u.confirmed_at || null, user_metadata: u.user_metadata || {},
  }));
  return {
    exported_at: new Date().toISOString(), business_id: businessId,
    preserved: ['businesses','stores','storefront_settings','auth.users (safe metadata only)','profiles','business_members','store_members'],
    preserved_data: { businesses: business, stores, storefront_settings: storefrontSettings, profiles, business_members: businessMembers, store_members: storeMembers, auth_users_safe_metadata: authUserRecords },
    tables: snapshot
  };
}
export async function POST(request: Request) {
  const auth = await authorize(request);
  if (auth instanceof NextResponse) return auth;
  let body: any;
  try { body = await request.json(); } catch { return NextResponse.json({ error: 'Invalid JSON body.' }, { status: 400 }); }

  if (body.action === 'preview') {
    try {
      const snapshot = await collectSnapshot(auth.admin, auth.businessId);
      const counts = Object.fromEntries(Object.entries(snapshot.tables).map(([k,v]) => [k, v?.length ?? 'not installed']));
      return NextResponse.json({ ok: true, businessId: auth.businessId, storeCount: 3, counts, preserved: snapshot.preserved });
    } catch (e: any) { return NextResponse.json({ error: e.message || 'Preview failed.' }, { status: 500 }); }
  }
  if (body.action === 'reset') {
    if (body.confirmation !== RESET_PHRASE) {
      return NextResponse.json({ error: `Type the exact confirmation phrase: ${RESET_PHRASE}` }, { status: 400 });
    }
    const groups = Array.isArray(body.groups) ? body.groups.map((x: any) => String(x)) : [];
    if (!groups.length) return NextResponse.json({ error: 'Select at least one cleanup group.' }, { status: 400 });
    const { data, error } = await auth.admin.rpc('mee_developer_reset_operational_data', { p_business_id: auth.businessId, p_groups: groups });
    if (error) return NextResponse.json({ error: `Reset did not complete: ${error.message}. Apply migration 20261102000100 first.` }, { status: 500 });
    return NextResponse.json({ ok: true, result: data });
  }
  return NextResponse.json({ error: 'Unknown action.' }, { status: 400 });
}
