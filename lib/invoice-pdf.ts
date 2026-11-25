export type InvoicePdfData = {
  invoice_no?: string; invoice_date?: string; status?: string; total_amount?: number;
  amount_paid?: number; balance_due?: number; billing_details?: any; terms_conditions?: string;
};

const ascii = (value: unknown) => String(value ?? '').normalize('NFKD').replace(/[^\x20-\x7E]/g, ' ').replace(/\\/g, '\\\\').replace(/\(/g, '\\(').replace(/\)/g, '\\)');
const wrap = (value: unknown, width = 88) => {
  const words = String(value ?? '').replace(/\s+/g, ' ').trim().split(' ');
  const rows: string[] = []; let row = '';
  for (const word of words) { if (!word) continue; if ((row + ' ' + word).trim().length > width && row) { rows.push(row); row = word; } else row = (row + ' ' + word).trim(); }
  if (row) rows.push(row); return rows;
};

export function createInvoicePdf(data: InvoicePdfData): Blob {
  const d = data.billing_details || {}; const seller = d.seller || {}; const customer = d.customer || {};
  const lines: string[] = [
    String(seller.name || 'MEE').toUpperCase(), ...wrap(seller.address || ''),
    `Phone: ${seller.phone || '-'}   GSTIN: ${seller.gstin || '-'}`,
    data.status === 'draft' ? 'BILL' : 'TAX INVOICE', `Invoice: ${data.invoice_no || 'Draft'}    Date: ${d.invoiceDate || data.invoice_date || '-'}`, 
    `Bill To: ${customer.name || 'Walk-in Customer'}`, `Phone: ${customer.phone || '-'}`,
    ...wrap(customer.address || ''), `GSTIN: ${customer.gstin || '-'}`, '',
    'ITEM                         QTY       PRICE       DISCOUNT       GST       TOTAL',
    '--------------------------------------------------------------------------------'
  ];
  for (const item of (d.items || [])) {
    const name = String(item.name || item.product_name_snapshot || 'Item');
    lines.push(...wrap(`${name} | ${item.quantity} ${item.unit || ''} | Rs.${Number(item.unit_price || 0).toFixed(2)} | Rs.${Number(item.discount_amount || 0).toFixed(2)} | ${Number(item.tax_rate || 0)}% | Rs.${Number(item.line_total || 0).toFixed(2)}`, 92));
  }
  lines.push('', `Taxable value: Rs.${Number(d.subtotal || 0).toFixed(2)}`, `GST included: Rs.${Number(d.tax || 0).toFixed(2)}`, `Discount: Rs.${Number(d.discount || 0).toFixed(2)}`, `GRAND TOTAL: Rs.${Number(data.total_amount || d.total || 0).toFixed(2)}`, `Received: Rs.${Number(data.amount_paid || 0).toFixed(2)}`, ...(Number(data.balance_due || 0) > 0 ? [`Balance due: Rs.${Number(data.balance_due || 0).toFixed(2)}`] : []), '', 'Notes:', ...wrap(d.notes || '-', 92), '', 'Terms & Conditions:', ...wrap(data.terms_conditions || '', 92));
  const pages: string[][] = []; for (let i = 0; i < lines.length; i += 48) pages.push(lines.slice(i, i + 48));
  const objects: string[] = []; const pageIds: number[] = []; const contentIds: number[] = [];
  objects[1] = '<< /Type /Catalog /Pages 2 0 R >>';
  objects[3] = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>';
  for (let p = 0; p < pages.length; p++) {
    const pageId = 4 + p * 2; const contentId = pageId + 1; pageIds.push(pageId); contentIds.push(contentId);
    const commands = ['BT', '/F1 9 Tf', '48 800 Td', '13 TL', ...pages[p].map((line, index) => `${index ? 'T* ' : ''}(${ascii(line)}) Tj`), 'ET'].join('\n');
    objects[contentId] = `<< /Length ${commands.length} >>\nstream\n${commands}\nendstream`;
    objects[pageId] = `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> /Contents ${contentId} 0 R >>`;
  }
  objects[2] = `<< /Type /Pages /Kids [${pageIds.map(id => `${id} 0 R`).join(' ')}] /Count ${pageIds.length} >>`;
  let pdf = '%PDF-1.4\n'; const offsets = [0];
  for (let id = 1; id < objects.length; id++) { offsets[id] = pdf.length; pdf += `${id} 0 obj\n${objects[id]}\nendobj\n`; }
  const xref = pdf.length; pdf += `xref\n0 ${objects.length}\n0000000000 65535 f \n`;
  for (let id = 1; id < objects.length; id++) pdf += `${String(offsets[id]).padStart(10, '0')} 00000 n \n`;
  pdf += `trailer\n<< /Size ${objects.length} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF`;
  return new Blob([pdf], { type: 'application/pdf' });
}
