'use client';
import {useCallback,useEffect,useMemo,useState} from 'react';
import {supabase} from '../../lib/supabase';
import {useMEE} from '../../lib/mee-context';
type Store={id:string;name:string}; type Product={id:string;store_id:string;name:string;sku:string|null;barcode:string|null;brand:string|null;selling_price:number;is_active:boolean;image_url?:string|null};
function makeEAN13(){const body='20'+Array.from({length:10},()=>Math.floor(Math.random()*10)).join('');const sum=body.split('').reduce((n,d,i)=>n+Number(d)*(i%2===0?1:3),0);return body+String((10-sum%10)%10)}
const L=['0001101','0011001','0010011','0111101','0100011','0110001','0101111','0111011','0110111','0001011'],G=['0100111','0110011','0011011','0100001','0011101','0111001','0000101','0010001','0001001','0010111'],R=['1110010','1100110','1101100','1000010','1011100','1001110','1010000','1000100','1001000','1110100'],P=['LLLLLL','LLGLGG','LLGGLG','LLGGGL','LGLLGG','LGGLLG','LGGGLL','LGLGLG','LGLGGL','LGGLGL'];
function bitsFor(c:string){
 const raw=String(c??'').replace(/\D/g,'');
 // EAN-13 encoding needs exactly 13 numeric digits. Keep the rightmost
 // 12 digits and add a leading zero for short/UPC-style values; never index
 // lookup tables with NaN or undefined.
 const payload=raw.length>=13?raw.slice(-13):raw.padStart(12,'0').slice(-12);
 const d=(payload.length===13?payload:'0'+payload).split('').map(n=>Number(n));
 const first=d[0]??0, parity=P[first]||P[0];
 let b='101';
 for(let i=1;i<=6;i++){const digit=d[i]??0;const table=parity[i-1]==='L'?L:G;b+=table[digit]||L[0]}
 b+='01010';
 for(let i=7;i<13;i++){const digit=d[i]??0;b+=R[digit]||R[0]}
 return b+'101';
}
function escapeHtml(value:string){return value.replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]||ch))}
function barcodeSvgMarkup(value:string){const b=bitsFor(value);const bars=b.split('').map((v,i)=>v==='1'?`<rect x="${i+3}" y="3" width="1" height="${(i<3||i>=b.length-3||(i>=45&&i<50))?48:42}"/>`:'').join('');return `<svg class="barcode" viewBox="0 0 ${b.length+6} 62" preserveAspectRatio="none"><rect width="100%" height="100%" fill="#fff"/><g fill="#111">${bars}</g><text x="50%" y="59" text-anchor="middle" font-size="8" letter-spacing="1">${escapeHtml(value)}</text></svg>`}

function Barcode({value}:{value:string}){const b=bitsFor(value);return <svg className="mee-ean" viewBox={`0 0 ${b.length+6} 62`} preserveAspectRatio="none" role="img" aria-label={`Barcode ${value}`} shapeRendering="crispEdges"><rect width="100%" height="100%" fill="white"/><g fill="#111">{b.split('').map((v,i)=>v==='1'?<rect key={i} x={i+3} y="3" width="1" height={(i<3||i>=b.length-3||(i>=45&&i<50))?48:42}/>:null)}</g><text x="50%" y="59" textAnchor="middle" fontSize="8" letterSpacing="1">{value}</text></svg>}
export default function BarcodeGeneratorPage(){const {stores,activeStoreId,setActiveStoreId}=useMEE();const db=supabase();const [storeId,setStoreId]=useState(''),[products,setProducts]=useState<Product[]>([]),[loading,setLoading]=useState(true),[saving,setSaving]=useState(false),[search,setSearch]=useState(''),[error,setError]=useState(''),[notice,setNotice]=useState(''),[selected,setSelected]=useState<string[]>([]),[labelWidth,setLabelWidth]=useState(50),[labelHeight,setLabelHeight]=useState(30),[printMode,setPrintMode]=useState<'sticker'|'a4'>('sticker'),[printPageIndex,setPrintPageIndex]=useState(0),[copiesByProduct,setCopiesByProduct]=useState<Record<string,number>>({});
useEffect(()=>{if(!storeId){const id=activeStoreId||stores[0]?.id||'';if(id)setStoreId(id)}},[storeId,activeStoreId,stores]);
const load=useCallback(async()=>{if(!db||!storeId){setProducts([]);setLoading(false);return}setLoading(true);setError('');const {data,error}=await db.from('products').select('id,store_id,name,sku,barcode,brand,selling_price,is_active,image_url').eq('store_id',storeId).order('name');if(error)setError(error.message);setProducts((data||[]) as Product[]);setSelected([]);setLoading(false)},[db,storeId]);useEffect(()=>{void load()},[load]);
const missing=useMemo(()=>products.filter(p=>!p.barcode?.trim()),[products]),filtered=useMemo(()=>products.filter(p=>`${p.name} ${p.brand||''} ${p.sku||''} ${p.barcode||''}`.toLowerCase().includes(search.toLowerCase())),[products,search]),printRows=products.filter(p=>selected.includes(p.id)&&p.barcode),printCopiesRows=printRows.flatMap(p=>Array.from({length:Math.max(1,Math.min(100,Math.floor(copiesByProduct[p.id]??1)))},()=>p)),a4Pages=Array.from({length:Math.ceil(printCopiesRows.length/40)},(_,i)=>printCopiesRows.slice(i*40,(i+1)*40));const printCurrentPage=()=>{
 if(!printRows.length)return;
 const esc=(value:string)=>value.replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]||ch));
 const makeLabel=(p:Product)=>{const nameLength=(p.name||'').trim().length;const nameFont=nameLength>42?6.2:nameLength>30?6.8:nameLength>22?7.4:8.2;const bits=bitsFor(p.barcode||'');const bars=bits.split('').map((v,i)=>v==='1'?`<rect x="${i+3}" y="2" width="1" height="${(i<3||i>=bits.length-3||(i>=45&&i<50))?46:40}"/>`:'').join('');return `<section class="label">${p.brand?`<div class="brand">${esc(p.brand)}</div>`:''}<div class="name" style="font-size:${Math.min(7.2,nameFont-1)}pt">${esc(p.name)}</div><svg class="barcode" viewBox="0 0 ${bits.length+6} 60" preserveAspectRatio="none"><rect width="100%" height="100%" fill="#fff"/><g fill="#111">${bars}</g><text x="50%" y="58" text-anchor="middle" font-size="8" letter-spacing="1">${esc(p.barcode||'')}</text></svg><div class="price">₹${Number(p.selling_price||0).toFixed(2)}</div></section>`};
 const isA4=printMode==='a4';
 const pageWidth=isA4?'210mm':`${labelWidth}mm`;
 const selectedRows=isA4?(a4Pages[printPageIndex]||[]):printCopiesRows;
 const rollJobHeight=`${selectedRows.length*labelHeight}mm`;
 const pageMarkup=isA4
   ? `<main class="a4-sheet">${selectedRows.map(makeLabel).join('')}</main>`
   : `<main class="roll">${selectedRows.map(makeLabel).join('')}</main>`;
 const pageRule=isA4
   ? `@page{size:A4 portrait;margin:5mm}`
   : `@page{size:${labelWidth}mm ${labelHeight}mm;margin:0}`;
 const layout=isA4
   ? `.a4-sheet{width:200mm;height:287mm;margin:0 auto;display:grid;grid-template-columns:repeat(4,47mm);grid-template-rows:repeat(10,27mm);column-gap:3.5mm;row-gap:1.7mm;align-content:start;justify-content:center}.label{width:47mm;height:27mm;padding:.7mm;gap:.25mm}.name{font-size:6.2pt;font-weight:500;line-height:1.02;max-height:4.8mm;min-height:0}.brand{font-size:7.8pt;font-weight:800;line-height:1;flex:0 0 2.8mm;height:2.8mm}.barcode{width:43mm;height:12.5mm}.price{font-size:7.5pt}`
   : `.roll{display:block;width:${labelWidth}mm;min-width:${labelWidth}mm;max-width:${labelWidth}mm;height:${rollJobHeight};min-height:${rollJobHeight};max-height:${rollJobHeight};margin:0;padding:0}.label{display:flex;flex-direction:column;align-items:center;justify-content:center;box-sizing:border-box;width:${labelWidth}mm;min-width:${labelWidth}mm;max-width:${labelWidth}mm;height:${labelHeight}mm;min-height:${labelHeight}mm;max-height:${labelHeight}mm;padding:1mm 1.5mm;gap:.12mm;margin:0;overflow:hidden;break-inside:avoid;page-break-inside:avoid}.label:not(:last-child){break-after:page;page-break-after:always}.label:last-child{break-after:auto!important;page-break-after:auto!important}.name{flex:0 0 ${Math.min(4.2,Math.max(3.2,labelHeight*.14))}mm;height:${Math.min(4.2,Math.max(3.2,labelHeight*.14))}mm;max-height:${Math.min(4.2,Math.max(3.2,labelHeight*.14))}mm;font-size:6.8pt;font-weight:500;line-height:1;align-content:center;overflow:hidden;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;align-self:stretch;white-space:normal;overflow-wrap:anywhere;text-align:center}.brand{flex:0 0 ${Math.min(2.8,Math.max(1.9,labelHeight*.093))}mm;height:${Math.min(2.8,Math.max(1.9,labelHeight*.093))}mm;max-height:${Math.min(2.8,Math.max(1.9,labelHeight*.093))}mm;font-size:9pt;line-height:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;text-align:center;font-weight:800}.barcode{flex:0 0 ${Math.min(10,Math.max(5,labelHeight*.34))}mm;width:${Math.max(20,labelWidth-4)}mm;height:${Math.min(10,Math.max(5,labelHeight*.34))}mm;max-height:${Math.min(10,Math.max(5,labelHeight*.34))}mm}.price{display:block;flex:0 0 ${Math.min(4.2,Math.max(3,labelHeight*.14))}mm;height:${Math.min(4.2,Math.max(3,labelHeight*.14))}mm;min-height:${Math.min(4.2,Math.max(3,labelHeight*.14))}mm;font-size:10.5pt;line-height:1;white-space:nowrap;overflow:visible;text-align:center;margin:0}`;
 const popup=window.open('','_blank','width=800,height=650');
 if(!popup){setError('Print popup blocked. Please allow popups for localhost:3000 and try again.');return}
 popup.document.open();
 popup.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>MEE ${isA4?'A4 Sheet':'Sticker Roll'} Print</title><style>
 *{box-sizing:border-box}html,body{margin:0!important;padding:0!important;background:#fff!important;color:#111!important;font-family:Arial,sans-serif;width:${pageWidth}!important;min-width:${pageWidth}!important;max-width:100%!important;height:${isA4?'auto':rollJobHeight}!important;min-height:0!important;max-height:${isA4?'none':rollJobHeight}!important}
 ${pageRule}
 .label{display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;overflow:hidden;break-inside:avoid;page-break-inside:avoid;margin:0 auto}
 .name{display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;flex-shrink:0;width:100%;font-weight:700;line-height:1.05;text-align:center;white-space:normal;overflow:hidden;overflow-wrap:anywhere}
 .barcode{display:block;flex:none;max-width:100%;object-fit:fill;margin:0 auto}
 .price{font-weight:700;line-height:1;text-align:center;flex-shrink:0}
 ${layout}
 @media print{html,body{margin:0!important;padding:0!important;width:${pageWidth}!important;min-width:${pageWidth}!important;max-width:100%!important;height:${isA4?'auto':rollJobHeight}!important;min-height:0!important;max-height:${isA4?'none':rollJobHeight}!important;overflow:hidden!important}*{-webkit-print-color-adjust:exact;print-color-adjust:exact}.roll{display:block!important;width:${labelWidth}mm!important;min-width:${labelWidth}mm!important;max-width:${labelWidth}mm!important;margin:0!important;padding:0!important}.roll>.label{box-sizing:border-box}.roll>.label:not(:last-child){break-after:page!important;page-break-after:always!important}.roll>.label:last-child{break-after:auto!important;page-break-after:auto!important;break-before:auto!important}}
 </style></head><body>${pageMarkup}<script>
 window.onload=()=>{document.title='MEE Print Ready';setTimeout(()=>{window.focus();window.print()},500)};
 window.onafterprint=()=>window.close();
 </script></body></html>`);
 popup.document.close();
};
const assign=async(ids:string[])=>{
 if(!db||!storeId||!ids.length||saving)return;
 setSaving(true);setError('');setNotice('');
 let done=0;let alreadyAssigned=0;const failures:string[]=[];
 for(const id of [...new Set(ids)]){
  const p=products.find(x=>x.id===id);
  if(!p)continue;
  if(p.barcode?.trim()){alreadyAssigned++;continue;}
  let saved=false;let lastError='';
  for(let attempt=0;attempt<15;attempt++){
   const code=makeEAN13();
   // IMPORTANT: SQL equality against NULL never matches. Use IS NULL for null barcodes.
   let update=db.from('products').update({barcode:code}).eq('id',id).eq('store_id',storeId);
   update=p.barcode===null?update.is('barcode',null):update.eq('barcode',p.barcode);
   const result=await update.select('id,barcode').maybeSingle();
   if(result.error){
    lastError=result.error.message;
    if(/duplicate|unique|products_store_id_barcode_key/i.test(lastError))continue;
    break;
   }
   if(result.data?.barcode===code){done++;saved=true;break;}
   // A concurrent request may have assigned a barcode after this page loaded.
   const check=await db.from('products').select('barcode').eq('id',id).eq('store_id',storeId).maybeSingle();
   if(check.error){lastError=check.error.message;break;}
   if(check.data?.barcode?.trim()){alreadyAssigned++;saved=true;break;}
   lastError='Update returned no row. Check Supabase RLS UPDATE policy and store access.';
   break;
  }
  if(!saved)failures.push(`${p.name}: ${lastError||'Unique barcode generate/save nahi ho paya.'}`);
 }
 await load();
 setSaving(false);
 if(failures.length){setError(failures.join(' · '));setNotice(`${done} barcode save hue; ${alreadyAssigned} pehle se assigned the; ${failures.length} failed.`);}
 else setNotice(`${done} missing barcode generate karke Supabase Products mein save aur verify kiye. ${alreadyAssigned} products pehle se barcode wale the. Products list refresh kar di gayi hai.`);
};
return <div className="page-stack mee-barcode-page" data-print-mode={printMode}><div className="page-heading"><div><span className="eyebrow">INVENTORY TOOLS</span><h1>Barcode Generator</h1><p className="muted">Generate missing barcodes for every product in this store, save them directly to Products, and print labels.</p></div><div className="page-actions"><button className="btn btn-outline" onClick={()=>void load()} disabled={loading||saving}>Refresh products</button><span className="status-pill">Selected: {printRows.length}</span></div></div>
<section className="panel barcode-toolbar-panel"><div className="form-grid"><label>Store<select value={storeId} onChange={e=>{setStoreId(e.target.value);setActiveStoreId(e.target.value)}}>{stores.map((s:Store)=><option key={s.id} value={s.id}>{s.name}</option>)}</select></label><label>Search product<input value={search} onChange={e=>setSearch(e.target.value)} placeholder="Product name, brand, SKU or barcode"/></label><div className="form-actions"><button className="btn btn-primary" disabled={saving||!missing.length} onClick={()=>void assign(missing.map(p=>p.id))}>{saving?'Generating…':`Generate all missing (${missing.length})`}</button></div></div><p className="muted">Creates EAN-13 internal-use codes (20 prefix), saves them in the existing products.barcode field, and prints labels for your wireless scanner.</p>{error&&<p className="error-text">{error}</p>}{notice&&<p className="success-text">{notice}</p>}</section>
<section className="panel barcode-settings-panel"><div className="panel-heading"><div><h2>Sticker size</h2><p className="muted">Photo ke sticker format ke liye starting size 50 × 30 mm rakha hai. Apne actual label ko measure karke width/height yahin adjust kar sakte hain.</p></div></div><div className="form-grid"><label>Sticker width (mm)<input type="number" min="25" max="80" step="1" value={labelWidth} onChange={e=>setLabelWidth(Math.min(80,Math.max(25,Number(e.target.value)||50)))}/></label><label>Sticker height (mm)<input type="number" min="15" max="100" step="1" value={labelHeight} onChange={e=>setLabelHeight(Math.min(100,Math.max(15,Number(e.target.value)||30)))}/></label><div className="form-actions"><span className="status-pill">Print size: {labelWidth} × {labelHeight} mm</span></div></div><p className="muted">Printer dialog mein same custom paper size select karein, scale 100%, margins 0/none aur headers/footers off rakhein.</p></section><section className="stats-grid barcode-stats"><article className="stat-card blue"><span className="stat-title">Store products</span><strong>{products.length}</strong></article><article className="stat-card orange"><span className="stat-title">Barcode missing</span><strong>{missing.length}</strong></article><article className="stat-card green"><span className="stat-title">Barcode assigned</span><strong>{products.length-missing.length}</strong></article></section>
<section className="panel barcode-products-panel"><div className="panel-heading"><div><h2>Product barcode list</h2><p className="muted">Select products to print existing barcode labels.</p></div><div className="page-actions"><button className="btn btn-outline btn-small" onClick={()=>setSelected(filtered.filter(p=>p.barcode).map(p=>p.id))}>Select printable</button><button className="btn btn-outline btn-small" onClick={()=>setSelected([])}>Clear selection</button></div></div><div className="table-wrap"><table><thead><tr><th>Select</th><th>Image</th><th>Product</th><th>Brand</th><th>SKU</th><th>Barcode</th><th>Copies</th><th>Action</th></tr></thead><tbody>{loading?<tr><td colSpan={8}>Loading products…</td></tr>:filtered.length===0?<tr><td colSpan={8} className="empty-cell">No products found.</td></tr>:filtered.map(p=><tr key={p.id}><td><input type="checkbox" checked={selected.includes(p.id)} disabled={!p.barcode} onChange={()=>setSelected(v=>v.includes(p.id)?v.filter(x=>x!==p.id):[...v,p.id])}/></td><td className="barcode-product-image-cell">{p.image_url?<img className="barcode-product-thumb" src={p.image_url} alt={p.name} loading="lazy"/>:<span className="barcode-product-no-image" aria-label="No product image">No image</span>}</td><td><b>{p.name}</b></td><td><b>{p.brand||'—'}</b></td><td>{p.sku||'—'}</td><td>{p.barcode||<span className="status-pill">Not generated</span>}</td><td><input aria-label={`Copies for ${p.name}`} type="number" min={1} max={100} step={1} value={copiesByProduct[p.id]??1} disabled={!p.barcode} onChange={e=>setCopiesByProduct(v=>({...v,[p.id]:Math.max(1,Math.min(100,Math.floor(Number(e.target.value)||1)))}))} style={{width:76,minHeight:34,padding:'5px 8px',border:'1px solid #9db9dc',borderRadius:6,fontWeight:700}}/></td><td>{!p.barcode?<button className="btn btn-primary btn-small" disabled={saving} onClick={()=>void assign([p.id])}>Generate</button>:<button className="btn btn-outline btn-small" onClick={()=>setSelected(v=>v.includes(p.id)?v.filter(x=>x!==p.id):[...v,p.id])}>{selected.includes(p.id)?'Selected':'Select label'}</button>}</td></tr>)}</tbody></table></div></section>
<section className="panel barcode-print-options"><div className="panel-heading"><div><h2>Print options</h2><p className="muted">Preview ke baad apna paper format choose karein. A4 par 40 labels per page (4 × 10); sticker roll par har label alag sticker par.</p></div></div><div className="mee-copies-control"><strong>Har product ke saamne Copies column mein alag quantity set karein. Sirf selected products print honge.</strong><strong>{printRows.length} selected barcodes · {printCopiesRows.length} total labels</strong></div><div className="page-actions"><button className="btn btn-primary" disabled={!printRows.length} onClick={()=>{setPrintMode('a4');setPrintPageIndex(0)}}>Preview A4 pages</button><button className="btn btn-outline" disabled={!printRows.length} onClick={()=>{setPrintMode('sticker');setPrintPageIndex(0)}}>Preview Sticker Roll</button></div><div className="form-grid"><label>Print format<select value={printMode} onChange={e=>{setPrintMode(e.target.value as 'a4'|'sticker');setPrintPageIndex(0)}}><option value="a4">A4 — 4 × 10 labels</option><option value="sticker">Sticker Roll — one page per selected sticker</option></select></label><label>{printMode==='a4'?'A4 sheet to print':'Sticker batch'}<select disabled={printMode==='sticker'} value={printPageIndex} onChange={e=>setPrintPageIndex(Number(e.target.value))}>{Array.from({length:printMode==='a4'?a4Pages.length:1},(_,i)=><option key={i} value={i}>{printMode==='a4'?`A4 sheet ${i+1} of ${a4Pages.length}`:`All ${printCopiesRows.length} sticker copies`}</option>)}</select></label><div className="form-actions"><button className="btn btn-primary" disabled={!printRows.length} onClick={printCurrentPage}>{printMode==='a4'?'Print this A4 sheet':`Print ${printCopiesRows.length} stickers`}</button></div></div><p className="muted">Sticker Roll prints exactly one custom-size page for each selected copy. A4 prints only the chosen sheet (up to 40 labels). No unselected products are included. A4: 4 × 10 (40 labels per sheet); last sheet contains only remaining selected products.</p></section><style jsx global>{`
.barcode-product-image-cell{width:76px;min-width:76px}.barcode-product-thumb{display:block;width:54px;height:54px;object-fit:contain;border:1px solid #dbe4ef;border-radius:8px;background:#fff;padding:3px}.barcode-product-no-image{display:flex;width:54px;height:54px;align-items:center;justify-content:center;text-align:center;border:1px dashed #cbd5e1;border-radius:8px;background:#f8fafc;color:#94a3b8;font-size:9px;padding:3px}.mee-copies-control{display:flex;flex-wrap:wrap;gap:8px 18px;align-items:center;padding:13px 16px;margin:14px 0;border:2px solid #1686ee;border-radius:10px;background:#eef6ff}.mee-copies-control strong{display:block;color:#064f9e;font-size:14px}
.mee-barcode-print{margin-top:16px;background:#fff;color:#111;padding:12px;border:1px solid #ddd;border-radius:8px}
.mee-barcode-print h2{font-size:16px;margin:0 0 12px}
.mee-sticker-pages{display:flex;flex-direction:column;align-items:center;gap:8px;padding:8px;background:#f3f4f6}
.mee-label{box-sizing:border-box;background:#fff;color:#111;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;overflow:hidden;break-inside:avoid;page-break-inside:avoid}
.mee-sticker-pages .mee-label{width:${labelWidth}mm;height:${labelHeight}mm;min-height:${labelHeight}mm;padding:1mm 1.5mm;gap:.12mm;margin:0 auto;justify-content:center}
.mee-label-name{width:100%;height:${Math.min(4.2,Math.max(3.2,labelHeight*.14))}mm;max-height:${Math.min(4.2,Math.max(3.2,labelHeight*.14))}mm;flex:0 0 ${Math.min(4.2,Math.max(3.2,labelHeight*.14))}mm;font-family:Arial,sans-serif;font-size:6.8pt;font-weight:500;line-height:1;align-content:center;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;white-space:normal;overflow:hidden;overflow-wrap:anywhere;text-align:center}
.mee-label-brand{width:100%;height:${Math.min(2.8,Math.max(1.9,labelHeight*.093))}mm;flex:0 0 ${Math.min(2.8,Math.max(1.9,labelHeight*.093))}mm;font-family:Arial,sans-serif;font-size:9pt;font-weight:800;line-height:1.1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;text-align:center}
.mee-ean{display:block;width:${Math.max(20,labelWidth-4)}mm;height:${Math.min(10,Math.max(5,labelHeight*.34))}mm;max-width:100%;object-fit:fill;margin:0 auto;flex:0 0 ${Math.min(10,Math.max(5,labelHeight*.34))}mm}
.mee-label-price{height:${Math.min(4.2,Math.max(3,labelHeight*.14))}mm;flex:0 0 ${Math.min(4.2,Math.max(3,labelHeight*.14))}mm;font-family:Arial,sans-serif;font-size:10.5pt;font-weight:700;line-height:1;white-space:nowrap}
.mee-a4-pages{display:block}
.mee-a4-page{width:200mm;min-height:287mm;margin:0 auto 12px;padding:0;display:grid;grid-template-columns:repeat(4,47mm);grid-template-rows:repeat(10,27mm);column-gap:3.5mm;row-gap:1.7mm;align-content:start;justify-content:center;background:#fff}
.mee-a4-page .mee-label{width:47mm;height:27mm;padding:1mm;gap:.4mm}
.mee-a4-page .mee-label-name{font-size:6.2pt;max-height:4.8mm}
.mee-a4-page .mee-label-brand{height:2.8mm;flex-basis:2.8mm;font-size:7.8pt;line-height:2.8mm;font-weight:800}
.mee-a4-page .mee-ean{width:43mm;height:12.5mm}
.mee-a4-page .mee-label-price{font-size:7.5pt}
@media print{
 @page{size:${printMode==='sticker'?`${labelWidth}mm ${labelHeight}mm`:'A4 portrait'};margin:0}
 html,body{margin:0!important;padding:0!important;background:#fff!important;width:auto!important}
 body *{visibility:hidden!important}
 .mee-barcode-print,.mee-barcode-print *{visibility:visible!important}
 .mee-barcode-print{position:absolute!important;left:0!important;top:0!important;width:${printMode==='sticker'?`${labelWidth}mm`:'210mm'}!important;margin:0!important;padding:0!important;border:0!important;background:#fff!important}
 .mee-barcode-print h2{display:none!important}
 .mee-sticker-pages{display:block!important;padding:0!important;margin:0!important;background:#fff!important}
 .mee-sticker-pages .mee-label{width:${labelWidth}mm!important;height:${labelHeight}mm!important;min-height:${labelHeight}mm!important;margin:0!important;padding:1mm 1.5mm!important;gap:.12mm!important;justify-content:center!important;break-after:avoid!important;page-break-after:avoid!important}
 .mee-sticker-pages .mee-label:not(.is-print-target){display:none!important}
 .mee-sticker-pages .mee-label-name{height:${Math.min(4.2,Math.max(3.2,labelHeight*.14))}mm!important;max-height:${Math.min(4.2,Math.max(3.2,labelHeight*.14))}mm!important;flex-basis:${Math.min(4.2,Math.max(3.2,labelHeight*.14))}mm!important}
  .mee-sticker-pages .mee-label-brand{height:${Math.min(2.8,Math.max(1.9,labelHeight*.093))}mm!important;flex-basis:${Math.min(2.8,Math.max(1.9,labelHeight*.093))}mm!important}
  .mee-sticker-pages .mee-ean{width:${Math.max(20,labelWidth-4)}mm!important;height:${Math.min(10,Math.max(5,labelHeight*.34))}mm!important;flex-basis:${Math.min(10,Math.max(5,labelHeight*.34))}mm!important}
 .mee-a4-pages{display:block!important;margin:0!important;padding:0!important}
 .mee-a4-page{display:none!important}
 .mee-a4-page.is-print-target{display:grid!important;width:200mm!important;height:287mm!important;min-height:287mm!important;margin:5mm auto!important;grid-template-columns:repeat(4,47mm)!important;grid-template-rows:repeat(10,27mm)!important;column-gap:3.5mm!important;row-gap:1.7mm!important;break-after:avoid!important;page-break-after:avoid!important}
 .mee-a4-page .mee-label{display:flex!important;width:47mm!important;height:27mm!important}
}
`}</style><section className="mee-barcode-print barcode-preview-panel"><h2>Print preview — {printMode==='a4'?'A4 sheet':'Sticker roll'}</h2><p className="muted">{printMode==='sticker'?`${printRows.length} selected products with individual copy counts = ${printCopiesRows.length} sticker pages (${labelWidth} × ${labelHeight} mm each).`:`A4 sheet ${printPageIndex+1} of ${a4Pages.length} — ${a4Pages[printPageIndex]?.length||0} labels.`}</p>{printRows.length===0?<p className="muted">Select products with an assigned barcode to preview printable labels.</p>:printMode==='sticker'?<div className="mee-sticker-pages">{printCopiesRows.map((p,i)=><article className="mee-label is-print-target" key={`${p.id}-${i}`}>{p.brand&&<div className="mee-label-brand">{p.brand}</div>}<div className="mee-label-name">{p.name}</div><Barcode value={p.barcode!}/><div className="mee-label-price">₹{Number(p.selling_price||0).toFixed(2)}</div></article>)}</div>:<div className="mee-a4-pages">{a4Pages.map((page,i)=><div className={`mee-a4-page ${i===printPageIndex?'is-print-target':''}`} key={i}>{page.map((p,labelIndex)=><article className={`mee-label ${printRows[printPageIndex]?.id===p.id?'is-print-target':''}`} key={`${p.id}-${labelIndex}`}>{p.brand&&<div className="mee-label-brand">{p.brand}</div>}<div className="mee-label-name">{p.name}</div><Barcode value={p.barcode!}/><div className="mee-label-price">₹{Number(p.selling_price||0).toFixed(2)}</div></article>)}</div>)}</div>}</section></div>}
