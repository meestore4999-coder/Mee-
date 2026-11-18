'use client';

import { useMemo, useState } from 'react';
import { useMEE } from '../../../lib/mee-context';

const RESET_PHRASE = 'RESET MEE OPERATIONAL DATA';
const CLEANUP_GROUPS = [
  { id: 'catalog_inventory', label: 'Products, categories, variants & stock', detail: 'Products, category records, variants, inventory balances and movements' },
  { id: 'sales_customers', label: 'Sales, invoices & customers', detail: 'Invoices/items, payments, customer ledgers, online orders/items and customers' },
  { id: 'purchasing_suppliers', label: 'Purchases, suppliers & supplier ledger', detail: 'Purchase records/items, supplier ledgers and suppliers' },
  { id: 'expenses', label: 'Expenses', detail: 'All business expense records' },
  { id: 'marketing', label: 'Banners & offers', detail: 'Store banners and promotional offers, if installed' },
  { id: 'audit', label: 'Audit logs', detail: 'Historical operational audit entries' },
] as const;
type Preview = { ok: boolean; businessId: string; counts: Record<string, number | string>; storeCount: number; preserved: string[] };

export default function DeveloperMaintenancePage() {
  const { session, role } = useMEE();
  const [developerKey, setDeveloperKey] = useState('');
  const [preview, setPreview] = useState<Preview | null>(null);
  const [busy, setBusy] = useState('');
  const [message, setMessage] = useState('');
  const [result, setResult] = useState<any>(null);
  const [selectedGroups, setSelectedGroups] = useState<string[]>(CLEANUP_GROUPS.map(g => g.id));
  const canAttempt = role === 'super_admin' && !!session?.access_token && developerKey.length >= 24;
  const total = useMemo(() => Object.values(preview?.counts || {}).reduce<number>((n, v) => n + (typeof v === 'number' ? v : 0), 0), [preview]);

  async function callApi(action: string, extra: Record<string, unknown> = {}) {
    if (!session?.access_token) throw new Error('Please sign in again.');
    const response = await fetch('/api/developer/maintenance', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${session.access_token}`, 'x-mee-developer-key': developerKey },
      body: JSON.stringify({ action, ...extra }),
      cache: 'no-store',
    });
    if (!response.ok) {
      const payload = await response.json().catch(() => ({}));
      throw new Error(payload.error || `Request failed (${response.status}).`);
    }
    return response;
  }
  async function loadPreview() {
    setBusy('preview'); setMessage(''); setResult(null); setPreview(null);
    try { const r = await callApi('preview'); const data = await r.json(); setPreview(data); setMessage('Preview ready. No database rows were changed.'); }
    catch (e: any) { setMessage(e.message || 'Preview failed.'); }
    finally { setBusy(''); }
  }
  async function resetData() {
    if (!window.confirm('FINAL WARNING: This permanently deletes operational records for this MEE business. The 3 stores, business, storefront settings and login access are protected. Continue?')) return;
    setBusy('reset'); setMessage(''); setResult(null);
    try {
      const r = await callApi('reset', { confirmation: RESET_PHRASE, groups: selectedGroups });
      const data = await r.json(); setResult(data.result); setMessage('Operational data reset completed. Preserved master data and access records were not targeted.');
      setPreview(null);
    } catch (e: any) { setMessage(e.message || 'Reset failed.'); }
    finally { setBusy(''); }
  }

  if (role !== 'super_admin') return <main className="panel" style={{ maxWidth: 680, margin: '40px auto', padding: 24 }}><h1>Not authorized</h1><p>This maintenance area is restricted.</p></main>;

  return <main style={{ maxWidth: 980, margin: '0 auto', display: 'grid', gap: 18 }}>
    <section className="panel" style={{ padding: 24, border: '1px solid #b7791f' }}>
      <p className="eyebrow">PRIVATE DEVELOPER AREA · NOT IN SIDEBAR</p>
      <h1 style={{ margin: '6px 0 8px' }}>MEE Data Maintenance</h1>
      <p className="muted">Developer-only operational data cleanup. The API verifies your signed-in Super Admin session and server-side developer key. No backup is required; selected operational data is permanently deleted after confirmation.</p>
      <label style={{ display: 'grid', gap: 7, marginTop: 18, maxWidth: 520 }}>Developer access key
        <input type="password" value={developerKey} onChange={e => { setDeveloperKey(e.target.value); setPreview(null); }} autoComplete="off" placeholder="Enter MEE_DEVELOPER_RESET_KEY" />
      </label>
      <p className="muted" style={{ fontSize: 12 }}>Configure the same 24+ character secret as MEE_DEVELOPER_RESET_KEY on the server/Vercel environment. Never put it in NEXT_PUBLIC variables or commit it to Git.</p>
      <button className="btn btn-primary" onClick={loadPreview} disabled={!canAttempt || !!busy}>{busy === 'preview' ? 'Checking…' : '1. Preview records'}</button>
    </section>

    {message && <div className={result ? 'success-notice' : 'notice'} role="status">{message}</div>}
    {preview && <section className="panel" style={{ padding: 24 }}>
      <h2>Deletion preview</h2>
      <p className="muted">Business: {preview.businessId || 'verified'} · Stores protected: {preview.storeCount} · Operational rows in scope: {total}</p>
      <div className="table-wrap"><table><thead><tr><th>Table</th><th>Records</th></tr></thead><tbody>{Object.entries(preview.counts).map(([name, count]) => <tr key={name}><td>{name}</td><td>{count}</td></tr>)}</tbody></table></div>
      <div style={{ marginTop: 20, padding: 16, borderRadius: 10, background: '#edf7ef' }}>
        <b>Protected records</b>
        <p style={{ marginBottom: 0 }}>Business master, exactly 3 store records, storefront settings/public URLs, Auth users, profiles, business memberships and store memberships.</p>
      </div>
      <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', marginTop: 20 }}>
        <button className="btn btn-outline" onClick={loadPreview} disabled={!!busy}>Refresh preview</button>
      </div>
      <div style={{ borderTop: '1px solid #ddd', marginTop: 22, paddingTop: 20 }}>
        <h3>Choose what to delete</h3>
        <p className="muted">Uncheck any category you want to keep. Dependencies are handled in the database transaction.</p>
        <div style={{ display: 'grid', gap: 12, margin: '14px 0 20px' }}>
          {CLEANUP_GROUPS.map(group => <label key={group.id} style={{ display: 'flex', gap: 10, alignItems: 'flex-start', padding: 12, border: '1px solid #ddd', borderRadius: 8 }}>
            <input type="checkbox" checked={selectedGroups.includes(group.id)} onChange={e => setSelectedGroups(old => e.target.checked ? [...old, group.id] : old.filter(x => x !== group.id))} />
            <span><b>{group.label}</b><small style={{ display: 'block', color: '#777' }}>{group.detail}</small></span>
          </label>)}
        </div>
        <h3 style={{ color: '#a12622' }}>Permanent deletion</h3>
        <p className="muted">No backup or typing step. Review the preview, then click Delete and confirm the browser warning to permanently remove selected records.</p>
        <button className="btn" style={{ marginTop: 14, background: '#a12622', color: '#fff' }} onClick={resetData} disabled={!canAttempt || selectedGroups.length === 0 || !!busy}>
          {busy === 'reset' ? 'Deleting…' : 'DELETE SELECTED DATA NOW'}
        </button>
      </div>
    </section>}
    {result && <section className="panel" style={{ padding: 24 }}><h2>Reset report</h2><pre style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{JSON.stringify(result, null, 2)}</pre></section>}
  </main>;
}
