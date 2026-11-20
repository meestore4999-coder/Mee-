# MEE GST-inclusive selling price and MRP update

- Product form now stores MRP separately from selling price.
- Selling price is treated as the final GST-inclusive amount.
- Billing extracts included GST from the selling price using: GST = gross - gross / (1 + rate/100).
- MRP is displayed for reference only and is never added to the bill or used as a tax base.
- Selling price cannot exceed a non-zero MRP.
- Invoice RPC persists taxable unit price and included GST while the invoice total remains the entered selling price.
- Existing invoices without `gstInclusive` print using their legacy tax-exclusive calculation.

The migration `20261120000200_mee_gst_inclusive_selling_and_mrp.sql` adds `products.mrp_price` and updates `create_mee_invoice`.

Example: MRP ₹150, selling price ₹118, GST 18% => taxable value ₹100, GST included ₹18, bill total ₹118. No GST is added on top of MRP.
