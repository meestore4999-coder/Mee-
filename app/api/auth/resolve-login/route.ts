import { NextResponse } from 'next/server';
import { createClient } from '@supabase/supabase-js';

// Resolve username to an email Auth identifier so username login never depends on Phone Auth.
// A phone-only account receives a non-deliverable internal alias email, confirmed via the Admin API.
export async function POST(request: Request) {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const service = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !service) {
    return NextResponse.json({ error: 'Username login setup incomplete: configure SUPABASE_SERVICE_ROLE_KEY on the server.' }, { status: 503 });
  }

  let body: { username?: unknown };
  try { body = await request.json(); } catch { return NextResponse.json({ error: 'Invalid login details.' }, { status: 400 }); }
  const username = String(body.username ?? '').trim().toLowerCase();
  if (!username || username.length > 100) return NextResponse.json({ error: 'Invalid login details.' }, { status: 400 });

  const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
  for (let page = 1; page <= 20; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) return NextResponse.json({ error: 'Username login service is unavailable. Check the server secret key.' }, { status: 503 });

    const users = data.users as Array<{ id: string; email?: string; user_metadata?: Record<string, unknown> }>;
    const found = users.find((u) => String(u.user_metadata?.username ?? '').trim().toLowerCase() === username);
    if (found) {
      // Prefer the user's real email. If the account is phone-only, assign a stable internal
      // alias so password verification uses email/password and does not require Phone Auth.
      let identifier = found.email;
      if (!identifier) {
        const alias = `mee-${found.id}@username-login.invalid`;
        const { data: updated, error: updateError } = await admin.auth.admin.updateUserById(found.id, {
          email: alias,
          email_confirm: true,
        });
        if (updateError || !updated.user?.email) {
          return NextResponse.json({ error: 'Could not prepare username login for this account. Check the Supabase server key and Auth settings.' }, { status: 503 });
        }
        identifier = updated.user.email;
      }
      return NextResponse.json({ identifier });
    }
    if (data.users.length < 1000) break;
  }
  return NextResponse.json({ error: 'Invalid login details.' }, { status: 401 });
}
