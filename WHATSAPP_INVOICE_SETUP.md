# MEE WhatsApp Invoice Delivery

## Store-wise modes
Open **Settings → WhatsApp Invoice Delivery** and choose per store:
- **Manual WhatsApp**: after a final invoice is saved, MEE opens WhatsApp with the customer's saved phone number and invoice summary. For PDF, MEE downloads the invoice PDF and opens WhatsApp; attach the downloaded PDF manually before sending.
- **WhatsApp API**: MEE sends the configured message or generated invoice PDF automatically through Meta WhatsApp Cloud API after a final invoice is saved. Draft bills are not sent.

## Meta WhatsApp Cloud API environment variables
Set these as server-side environment variables in Vercel (Production and Preview as required), then redeploy:

- `MEE_WHATSAPP_PHONE_NUMBER_ID` — Meta WhatsApp Cloud API Phone Number ID (not the display phone number).
- `MEE_WHATSAPP_ACCESS_TOKEN` — server-side access token with WhatsApp messaging permissions. Never expose it as a `NEXT_PUBLIC_` variable.
- `MEE_WHATSAPP_GRAPH_VERSION` — optional, defaults to `v23.0`.

The API route requires a signed-in MEE session and verifies the user's store access under Supabase RLS before sending.

## Meta policy notes
Meta may require an approved message template when starting a business-initiated conversation outside the 24-hour customer-service window. A successful API response means Meta accepted the message request; delivery status is still governed by WhatsApp. Ensure the recipient has provided the required opt-in.
