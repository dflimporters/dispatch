# DFL Dispatch — Load Board

Live at **https://dflimporters.github.io/dispatch/** (GitHub Pages, `main` branch, repo root).
Pushing to `main` deploys; there is no build step. One self-contained file: `index.html`.

Separate from the staff portal (`dflimporters/app` → dflhq.com) so it can ship without the
portal's pull-request flow. Both use the same Supabase project (`hzagwndglwhcepsirafi`).

## What it does

Three sections, switched at the top of the page:

- **Overview** — outbound shipments per shipping zone (or per trucker/ShipVia): shipments,
  drops, fill rate, volume split batched vs. not, and best-fit trucks needed.
- **Logistics clerk** — one card per `BATCHnn` placeholder batch. The clerk logs calls to
  haulage contractors and confirms one; confirming freezes the batch's shipment list.
- **Batcher** — read-only. For each confirmed batch: which ShipVia to set on which shipments
  in Acumatica, and whether that's been done (applied / to do / mismatch).

Duties are split on purpose: the batcher groups shipments but never picks the contractor.

## Rules

- **Batched** = the shipment has a ShipVia. **Placeholder** = a ShipVia starting `BATCH`
  (a fixed pool in Acumatica, reused daily; a batch is identified by shipment date + code).
- **Outbound only**: `operation = 'Issue'` and not an `RC` order. Returns are excluded.
- **Drop** = one customer stop. **Max 10 drops per truck.**
- **Trucks needed** = best fit per zone: fewest trucks meeting both volume and drops, then the
  smallest total capacity. Zones are planned independently.
- **Fill** compares shipped qty with what was still *owed* (not the full order), so later
  shipments on a part-shipped order don't look short.

## Data (Supabase)

| Table | Source | Refresh |
|---|---|---|
| `shipments` | Acumatica GI `SO-Shipment` (joins SOOrderShipment + SOOrder) | `sync-shipments` edge function, every 5 min, ~5am–8pm Jamaica |
| `ship_via_codes` | Acumatica GI `SO-ShipViaCode` | `sync-ship-via-codes`, hourly |
| `truck_types` | Maintained by hand (Van 120, 5 Ton 400, 10 Ton 800, 12 Ton 900) | — |
| `batch_assignments` | Written by the clerk section | — |
| `batch_events` | Append-only log of calls, confirmations, undos | — |

Edge functions and cron jobs live in Supabase, not in this repo.

## ⚠ Testing mode — no sign-in

Requests go out with the public (anon) key. Temporary RLS policies allow it:

- read: `shipments_read_anon`, `truck_types_read_anon`, `ship_via_codes_read`
- clerk writes: `batch_assignments_{read,insert,update}_test`
- log: `batch_events_{read,insert}_test` (no update/delete, even now)

Anyone with the URL can read shipments and edit assignments, and "Your name" is honour-system.

**Before real use:** add sign-in (phone OTP needs no extra setup; Microsoft SSO needs this
site's URL added to the Azure and Supabase redirect allow-lists), replace the `*_test`
policies with role-scoped ones (clerk writes, batcher reads), drop the anon read policies, and
take names from the signed-in profile. Sessions are **not** shared with dflhq.com.

## Working on it

Serve the folder locally (e.g. `npx http-server . -p 3000 -c-1`) and open it; don't use
`file://`. Test writes against a far-past date (e.g. 2020-01-01) and delete them afterwards.
