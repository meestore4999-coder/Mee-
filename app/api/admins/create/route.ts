import { NextResponse } from 'next/server';
import { createClient } from '@supabase/supabase-js';

export async function POST(request: Request) {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  const service = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !anon || !service || /PASTE_SERVER_ONLY|PLACEHOLDER|YOUR_SERVICE_ROLE|YOUR_SUPABASE/i.test(service)) {
    return NextResponse.json({ error: 'Server setup incomplete: set the real Supabase secret/service_role key in SUPABASE_SERVICE_ROLE_KEY in .env.local. The current value is missing or a placeholder. Never use the publishable/anon key here and never prefix this variable with NEXT_PUBLIC_.' }, { status: 503 });
  }
  const authorization = request.headers.get('authorization') || '';
  const token = authorization.startsWith('Bearer ') ? authorization.slice(7) : '';
  if (!token) return NextResponse.json({ error: 'Sign in as Super Admin first.' }, { status: 401 });
  const authClient = createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: authData, error: authError } = await authClient.auth.getUser(token);
  if (authError || !authData.user) return NextResponse.json({ error: 'Session invalid. Please sign in again.' }, { status: 401 });
  // Use the verified JWT to identify the caller, then use the server-only
  // service client to read membership. RLS may intentionally hide membership
  // rows from ordinary client SELECT queries, which previously caused a false
  // "no membership" error even when the user was a Super Admin.
  const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: memberships, error: memberError } = await admin
    .from('business_members')
    .select('business_id,role')
    .eq('user_id', authData.user.id);
  if (memberError) {
    console.error('Store-admin authorization membership lookup failed:', memberError.message);
    return NextResponse.json({ error: `Could not verify your MEE membership (${memberError.code || 'DB_ERROR'}): ${memberError.message}` }, { status: 500 });
  }
  const superAdminMembership = (memberships || []).find((m: any) => m.role === 'super_admin');
  if (!superAdminMembership) {
    const currentRoles = (memberships || []).map((m: any) => String(m.role)).filter(Boolean);
    return NextResponse.json({
      error: currentRoles.length
        ? `Your account is not registered as MEE Super Admin (current role: ${currentRoles.join(', ')}).`
        : 'No MEE business membership was found for the authenticated account. Verify the signed-in Auth user ID and business_members row.'
    }, { status: 403 });
  }
  const businessId = superAdminMembership.business_id;
  let body: any;
  try { body = await request.json(); } catch { return NextResponse.json({ error: 'Invalid request.' }, { status: 400 }); }
  const username = String(body.username || '').trim();
  const password = String(body.password || '');
  const phoneInput = String(body.phone || '').trim();
  const emailInput = String(body.email || '').trim().toLowerCase();
  const phoneDigits = phoneInput.replace(/\D/g, '');
  const phone = !phoneInput ? '' : (phoneInput.replace(/[\s()-]/g, '').startsWith('+') ? phoneInput.replace(/[\s()-]/g, '') : (phoneDigits.length === 10 ? '+91' + phoneDigits : '+' + phoneDigits));
  const fullName = String(body.fullName || username).trim();
  const storeId = String(body.storeId || '');
  if (!username || username.length < 3 || !/^[a-zA-Z0-9._-]+$/.test(username) || (emailInput && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(emailInput)) || (phoneInput && phoneDigits.length < 10) || password.length < 8 || !storeId) return NextResponse.json({ error: 'Username (3+ characters, letters/numbers/._-), store and password (minimum 8 characters) are required. Email and phone are optional.' }, { status: 400 });
  // Supabase Auth requires an email or phone identifier. For username-only accounts,
  // create a confirmed, non-deliverable internal alias; username login resolves it
  // server-side through /api/auth/resolve-login. This does not require a phone number.
  const email = emailInput || (!phone ? `mee-${crypto.randomUUID()}@username-login.invalid` : '');
  const { data: store, error: storeError } = await admin.from('stores').select('id,business_id,name').eq('id', storeId).eq('business_id', businessId).maybeSingle();
  if (storeError || !store) return NextResponse.json({ error: 'Selected store does not belong to this MEE business.' }, { status: 400 });
  const { data: existingUsers, error: listError } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
  if (listError) return NextResponse.json({ error: 'Could not validate existing login IDs.' }, { status: 500 });
  const duplicate = existingUsers.users.some((u:any) => (emailInput && u.email?.toLowerCase() === emailInput) || (phone && u.phone === phone) || String(u.user_metadata?.username || '').toLowerCase() === username.toLowerCase());
  if (duplicate) return NextResponse.json({ error: 'This email, phone number, or username is already registered.' }, { status: 409 });
  const { data: created, error: createError } = await admin.auth.admin.createUser({ email, email_confirm: true, ...(phone ? { phone, phone_confirm: true } : {}), password, user_metadata: { username, full_name: fullName, username_only: !emailInput && !phone } });
  if (createError || !created.user) return NextResponse.json({ error: createError?.message || 'Could not create authentication user.' }, { status: 400 });
  const userId = created.user.id;
  const profile = await admin.from('profiles').upsert({ id: userId, full_name: fullName, phone: phone || null, is_active: true });
  if (profile.error) { await admin.auth.admin.deleteUser(userId); return NextResponse.json({ error: 'Profile creation failed: ' + profile.error.message }, { status: 500 }); }
  const businessMember = await admin.from('business_members').insert({ business_id: businessId, user_id: userId, role: 'store_admin' });
  if (businessMember.error) { await admin.auth.admin.deleteUser(userId); return NextResponse.json({ error: 'Business access assignment failed: ' + businessMember.error.message }, { status: 500 }); }
  const storeMember = await admin.from('store_members').insert({ store_id: store.id, user_id: userId, role: 'store_admin' });
  if (storeMember.error) { await admin.from('business_members').delete().eq('business_id', businessId).eq('user_id', userId); await admin.auth.admin.deleteUser(userId); return NextResponse.json({ error: 'Store access assignment failed: ' + storeMember.error.message }, { status: 500 }); }
  return NextResponse.json({ ok: true, username, email: emailInput || null, phone: phone || null, fullName, storeName: store.name, message: `Store admin created for ${store.name}. Login with username and password${emailInput ? ', or email and password' : ''}${phone ? ', or phone and password' : ''}.` });
}
