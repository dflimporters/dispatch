# DFL Dispatch — Load Board

Live at **https://dflimporters.github.io/dispatch/** (GitHub Pages, `main` branch, repo root).
Pushing to `main` deploys; there is no build step.

Separate from the staff portal (`dflimporters/app` → dflhq.com) so it can ship without the
portal's pull-request flow. Both use the same Supabase project (`hzagwndglwhcepsirafi`).

## Pages

| Page | Who | Sign-in |
|---|---|---|
| `index.html` | Overview: shipments per zone or per trucker, fill, best-fit trucks. Still has the old BATCH-placeholder clerk/batcher sections until the new pages replace them. | none (anon) |
| `batcher.html` | **Internal Logistics Coordinator** (was "batcher"): builds loads from open shipments, suggested per zone and wave; move/merge/split, truck type, send to the liaison. | Microsoft, `batcher` role |
| `transfers.html` | **Transfer lists** (coordinator): numbered, time-bound lists (TR-MMDD-NN) of items bumped off shipments, Ashenheim → 71. Draft → Sent; print / CSV. | Microsoft, `batcher` role |
| `clerk.html` | **Trucker Liaison** (was "clerk"): logs trucker calls, locks in a trucker per load (writes ShipVia + LOADNBR). | Microsoft, `clerk` role |
| `picking.html` | **Picking** by load, split by area 1–4, phone/tablet first. Records picked qty per item. | Microsoft, `picker` role |
| `checker.html` | **Checker**: picked vs shipped per shipment line, lowers/zeroes lines, then Confirm Shipment in Acumatica. | Microsoft, `checker` role |

`common.js` / `common.css` are shared by the signed-in pages. Role keys in the database stay
`batcher` / `clerk`; only the visible names changed.

Duties are split on purpose: the batcher builds loads but never picks the trucker; the clerk
picks the trucker but can't change what's on a load (it can send a load back with a reason).

## Load flow

1. **Batcher** builds loads (`draft`) and sends them to the clerk (`ready`).
2. **Clerk** calls truckers, logs the calls, and locks one in (`confirmed`).
3. That immediately runs the **`dispatch-acu`** edge function (`writing`). For each shipment it:
   - checks it's still On Hold/Open with the ShipVia it had at confirmation,
   - sets **ShipVia** and the **load number** (UDF, default `LOADNBR`), takes it off hold,
   - reads it back (it should now be **Open**),
   - and stops. It does **not** confirm. The shipment stays Open for picking, and the
     checker step (being built) confirms it once the pick has been checked.
4. The load ends `done`, or `partial` if any shipment was refused (changed in Acumatica) or
   failed. Failed ones can be retried by the clerk; refused ones are moved by the batcher.

Load number: **`L-MMDD-AM-NN`** (e.g. `L-0928-AM-03`), next free sequence per date and wave.
Only drafts can change wave, so a number that reached Acumatica never changes.

BATCHnn placeholders are no longer needed: a shipment still carrying one counts as unloaded.

## Picking and checking

1. A load can be picked once its trucker is locked in (`done`/`partial`). The pick list is
   consolidated per item across the load's shipments (`dispatch_pick_list`), split by area
   (`pick_area_of`: per-item list, else a placeholder by item class).
2. Pickers record what they picked (`pick_lines`) and mark each area done (`pick_area_status`).
3. The checker sets what goes out on each shipment line (`check_lines`; only lowering is allowed).
   The default splits a short pick over the shipments in order, shortfall on the last ones.
4. **Confirm in Acumatica** runs `dispatch-acu` `check_confirm`: lowers or deletes lines, sets
   Control Qty, Confirm Shipment, reads it back. `loads.check_status` ends `confirmed` or `partial`.
   Live loads need `DISPATCH_LIVE_CHECKER=on` as well as `DISPATCH_LIVE_WRITEBACK=on`.

## Transfers

Built from what was **bumped off shipments**: per open SO order line, what's still open minus
what made it onto open shipments (`dispatch_transfer_preview`). That catches short lines and
lines Acumatica left off entirely; orders with no shipment at all count where 71 couldn't cover them.

- Each list covers shipments created since the previous list's cut-off (first one: last 24 h).
  Sections: **new this run** and **still short from earlier**.
- Suggested = bumped + extra %. Ashenheim's stock isn't used: Ashenheim decides what it can send.
- **Build** saves a numbered draft (`transfer_lists` / `transfer_lines`); one draft at a time.
  **Mark sent** freezes it. Items on a list sent in the last 24 h show as in transit; after that,
  anything still short returns, so items Ashenheim never sent don't drop off.
- No receiving step yet: later the portal will read completed Transfer Orders from Acumatica.

## Live line items

Production's SO-Shipment GI has no lines, so `dispatch-acu` `sync_live_lines` reads Open/On Hold
shipments' lines through the REST Shipment entity every 5 minutes (cron
`dispatch-live-lines-5min`, authorised by the Vault secret `dispatch_cron_token`), into
`shipment_lines` (env `live`) and `shipments.shipment_value`. Needs the `ACU_LIVE_*` login.

## Rules

- **Outbound only**: `operation = 'Issue'` and not an `RC` order. Returns are excluded.
- **Loadable**: On Hold/Open, no real ShipVia (empty or BATCH), not already on a load.
- **Drop** = one customer stop. **Max 10 drops per truck.**
- **Best fit** = fewest trucks meeting both volume and drops, then the smallest total capacity.
- **Suggested wave**: AM if created before 8am Jamaica on the load date (or dated earlier),
  else PM. Only a suggestion; the batcher sets it.
- **Fill** (Overview) compares shipped qty with what was still *owed*.

## TEST vs live

Both signed-in pages have a Test/Live switch (remembered per device).

- **Test**: shipments come from `shipments_test`, pulled from the test target by
  `dispatch-acu` (`sync_test`, the "Pull fresh TEST data" button). The trucker list is cut down
  to a few long-standing truckers that exist in TEST (`TEST_TRUCKERS` in `common.js`).
  The secret `DISPATCH_TEST_TARGET` picks the target:
  - `test` (default): the 2024R2 **TEST** tenant. Refuses unless `ACU_SHIPVIA_TENANT` is exactly `TEST`.
  - `sandbox26`: the **2026R1 sandbox** (`dflimporters-sandbox-26-1.acumatica.com`, tenant
    `DFL Importers`). Same API login unless `ACU_SANDBOX_USERNAME/PASSWORD` are set.
    Blocked for now: a Shipments customization fails on 2026R1 (see `acu-probe`).
- **Live**: shipments come from `shipments`. Loads can be built, but writeback is refused until
  the `DISPATCH_LIVE_WRITEBACK=on` and `ACU_LIVE_USERNAME/PASSWORD/TENANT` secrets are set.

Test and live loads never mix (`env` column on every load table).

**Acumatica API limits.** Production allows 6 concurrent requests and 150 per minute; the
sandbox allows 1 and 50. `dispatch-acu` runs one job at a time per target (lease in
`acu_leases`; a second job waits up to a minute, then reports "busy"). It also spaces its calls
(1.0 s apart on production and TEST, 1.3 s on the sandbox).

## Data (Supabase)

| Table | Source | Refresh |
|---|---|---|
| `shipments` | Acumatica GI `SO-Shipment` (production) | `sync-shipments`, every 5 min, ~5am–8pm Jamaica |
| `shipments_test` | TEST tenant, REST `Shipment` entity (the TEST API user can't see the GI); customer names joined from `customers` | `dispatch-acu` `sync_test`, on demand |
| `shipment_lines` | Items per shipment (item, description, UOM, ordered vs shipped, value) for the expandable rows. TEST: filled by `sync_test`. Live: no source yet (the GI has no lines). | with the TEST pull |
| `dispatch_test_orders` | Log of real orders copied into TEST by `dispatch-test-seed` (test volume) | by hand |
| `ship_via_codes` | Acumatica GI `SO-ShipViaCode` | `sync-ship-via-codes`, hourly |
| `truck_types` | Maintained by hand (Van 120, 5 Ton 400, 10 Ton 800, 12 Ton 900) | — |
| `dispatch_roles` | Who is a `batcher` / `clerk`. Granted by hand in SQL. | — |
| `loads`, `load_shipments`, `load_events` | Written only through the `dispatch_*` functions and `dispatch-acu` | — |
| `batch_assignments`, `batch_events` | Old placeholder flow (index.html). Drop once the new pages are in use. | — |
| `pick_areas`, `pick_area_classes`, `pick_area_items` | Which warehouse area (1–4) picks an item: per-item override, else by item class (`pick_area_of()`). Class rules are a **placeholder** until the warehouse manager's mapping arrives. | by hand |
| `acu_leases` | One Acumatica job at a time per target (see API limits above) | by the edge functions |

Schema and functions: `supabase/migrations/`. Edge function source: `supabase/functions/`.
These are deployed by hand; the other edge functions and cron jobs exist only in Supabase:
- `dispatch-acu`: the pages' route into Acumatica.
- `dispatch-test-seed`: test volume.
- `acu-probe`: a read-only sandbox check. Call it with POST and header `x-test-token`.

The load tables are read-only through RLS for anyone with a dispatch role; every change goes
through a `security definer` function that checks the caller's role and the load's status.

Grant a role:

```sql
insert into dispatch_roles (user_id, role)
select id, 'clerk' from auth.users where email = 'someone@dflimporters.com';
```

The person must have signed in once (on dflhq.com or here) so they exist in `auth.users`.

## Sign-in

Microsoft SSO through Supabase. Azure only redirects to the Supabase callback, so nothing
changes there; this site's URL (and `http://localhost:3000`) are in Supabase's Redirect URLs.
Sessions are **not** shared with dflhq.com.

`index.html` is still unguarded (anon key, temporary `*_anon` / `*_test` policies) until its old
sections are retired.

## Working on it

Serve the folder locally (`npx http-server . -p 3000 -c-1`, or the `dispatch` entry in
`.claude/launch.json`) and open it; don't use `file://`. Test with the switch on **Test**.
