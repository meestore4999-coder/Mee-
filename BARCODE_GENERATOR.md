# MEE Barcode Generator

A dedicated `/barcodes` page is available from the workspace sidebar as **Barcode Generator**.

- Select a store to keep product barcode assignment store-scoped.
- Products with a null or empty `products.barcode` value are shown as missing.
- Generate one barcode per product or generate all missing barcodes in the selected store.
- Generated values are valid EAN-13 internal-use numbers using the `20` prefix and are saved to the existing `products.barcode` field.
- Select generated products and use **Print selected labels** to print product name, barcode, selling price and SKU.
- No database migration is required: the connected MEE database already has `products.barcode` and a unique `(store_id, barcode)` index.

The labels are intended for in-store use, not as globally GS1-registered retail GTINs. Confirm scanner compatibility and print size with a physical test label before bulk printing.
