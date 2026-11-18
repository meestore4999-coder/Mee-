# Udyama POS 211W Wireless Barcode Scanner + MEE

## What is now supported in this source
- Product form has a dedicated `Barcode / Scan` field. With the field focused, the scanner types the barcode into it; save the product to store the code in `public.products.barcode`.
- Billing modal has a `Scan barcode to add product` field. Scanning a saved barcode (or SKU) and sending Enter adds that product to the current bill. Re-scanning the same product increments its quantity.
- Product lookup is restricted to the selected store's active catalogue because billing loads products by `store_id` and `is_active`.
- Existing database schema already has `products.barcode` and a unique index on `(store_id, barcode)`. No barcode migration is needed.
- Existing final-invoice RPC workflow remains responsible for invoice creation and stock deduction; scanner integration only adds catalog products to the bill lines.

## First-time scanner connection (Windows)
1. Charge / insert the scanner receiver dongle if supplied with the unit.
2. Plug the USB receiver into the billing PC. If the unit supports USB cable mode, connect it directly.
3. Turn on the scanner and pair it with its receiver according to the device quick-start sheet.
4. Open Notepad and scan any printed barcode. If digits appear as keyboard text, Windows recognises it as a keyboard-wedge scanner; no COM port or special driver is required for this mode.
5. In the scanner manual, set the suffix to `Enter` (often called CR / CRLF / Enter suffix). The scanner must send the barcode followed by Enter for automatic billing lookup.
6. In MEE Products > Add Product, click / focus `Barcode / Scan`, scan the item's barcode, complete product name, prices, GST and stock, then save.
7. In MEE Billing > Create New Bill, keep focus in `Scan barcode to add product`, scan the saved item. It should be inserted into the bill. Re-scan to increment quantity.

## Important
- A scanner cannot invent a product name, price, GST or opening stock from a barcode. The product must first be registered in the correct store, unless a separate product-master lookup provider is configured.
- If Notepad does not receive barcode characters, pair / charge the scanner and consult the device's pairing instructions. The photos show model 211W but do not show its receiver, pairing barcode sheet, or exact wireless mode; do not scan random setup barcodes.
- For testing, use a harmless sample product and a printed barcode. Do not test by finalising a real customer invoice. Verify draft first.
- Supabase connection in this project is configured through `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` in the local `.env.local`; never put a service-role key in the browser app.
