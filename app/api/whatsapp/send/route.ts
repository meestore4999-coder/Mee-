import { NextRequest, NextResponse } from 'next/server';
import { createClient } from '@supabase/supabase-js';

export const runtime = 'nodejs';

export async function POST(request: NextRequest) {
  try {
    const auth = request.headers.get('authorization') || '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
    if (!token) return NextResponse.json({ error: 'Login session missing. Please sign in again.' }, { status: 401 });
    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
    if (!supabaseUrl || !anonKey) return NextResponse.json({ error: 'Supabase authentication is not configured.' }, { status: 500 });
    const authClient = createClient(supabaseUrl, anonKey, { auth: { persistSession: false, autoRefreshToken: false }, global: { headers: { Authorization: `Bearer ${token}` } } });
    const { data: userData, error: authError } = await authClient.auth.getUser(token);
    if (authError || !userData.user) return NextResponse.json({ error: 'Your login session is invalid. Please sign in again.' }, { status: 401 });

    const phoneNumberId = process.env.MEE_WHATSAPP_PHONE_NUMBER_ID;
    const accessToken = process.env.MEE_WHATSAPP_ACCESS_TOKEN;
    const graphVersion = process.env.MEE_WHATSAPP_GRAPH_VERSION || 'v23.0';
    if (!phoneNumberId || !accessToken) return NextResponse.json({ error: 'WhatsApp Cloud API is not configured. Add MEE_WHATSAPP_PHONE_NUMBER_ID and MEE_WHATSAPP_ACCESS_TOKEN in Vercel Environment Variables.' }, { status: 503 });

    const body = await request.json();
    const storeId = String(body.storeId || '');
    if (!storeId) return NextResponse.json({ error: 'Store context is required.' }, { status: 400 });
    const { data: allowedStore, error: storeError } = await authClient.from('stores').select('id').eq('id', storeId).maybeSingle();
    if (storeError || !allowedStore) return NextResponse.json({ error: 'You do not have access to this store.' }, { status: 403 });
    const to = String(body.to || '').replace(/\D/g, '');
    const message = String(body.message || '').trim();
    if (to.length < 10 || to.length > 15) return NextResponse.json({ error: 'Customer WhatsApp number is invalid. Include country code.' }, { status: 400 });
    const endpoint = `https://graph.facebook.com/${graphVersion}/${phoneNumberId}`;
    const headers = { Authorization: `Bearer ${accessToken}` };
    let payload: any;
    if (body.pdfBase64) {
      const bytes = Buffer.from(String(body.pdfBase64).replace(/^data:application\/pdf;base64,/, ''), 'base64');
      if (!bytes.length || bytes.length > 15 * 1024 * 1024) return NextResponse.json({ error: 'Invoice PDF is empty or larger than 15 MB.' }, { status: 400 });
      const form = new FormData();
      form.append('messaging_product', 'whatsapp');
      form.append('type', 'application/pdf');
      form.append('file', new Blob([bytes], { type: 'application/pdf' }), String(body.filename || 'MEE-Invoice.pdf'));
      const upload = await fetch(`${endpoint}/media`, { method: 'POST', headers, body: form });
      const uploaded = await upload.json();
      if (!upload.ok || !uploaded.id) return NextResponse.json({ error: uploaded.error?.message || 'WhatsApp PDF upload failed.' }, { status: 502 });
      payload = { messaging_product: 'whatsapp', recipient_type: 'individual', to, type: 'document', document: { id: uploaded.id, filename: String(body.filename || 'MEE-Invoice.pdf'), caption: message.slice(0, 1024) } };
    } else {
      if (!message) return NextResponse.json({ error: 'WhatsApp message is empty.' }, { status: 400 });
      payload = { messaging_product: 'whatsapp', recipient_type: 'individual', to, type: 'text', text: { preview_url: false, body: message.slice(0, 4096) } };
    }
    const sent = await fetch(`${endpoint}/messages`, { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    const result = await sent.json();
    if (!sent.ok) return NextResponse.json({ error: result.error?.message || 'WhatsApp message could not be sent.', details: result.error?.error_data?.details }, { status: 502 });
    return NextResponse.json({ success: true, messageId: result.messages?.[0]?.id || null });
  } catch (error: any) {
    return NextResponse.json({ error: error?.message || 'Unexpected WhatsApp send error.' }, { status: 500 });
  }
}
