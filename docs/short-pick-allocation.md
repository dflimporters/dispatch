# Short-pick allocation: design memo

Agreed with Joel 2026-10-27. Status: decided, not built.

## Problem
Acumatica says stock is X, the picker finds less. The load is short on a SKU, so not every
customer on it can get everything ordered.

## Today
- `pick_lines`: picked qty per SKU for the whole load. `check_items`: checked qty per SKU.
- Invoicing (supervisor) spreads the checked qty over the shipments in shipment-number order
  (`pDefaults` in `invoicing.html`), so the shortfall lands on the last shipments. The
  supervisor can edit the split; it is saved to `check_lines` (`final_qty`, `note`).
- `check_confirm` lowers or deletes the Acumatica shipment lines, sets Control Qty and confirms.
  The invoice is made from the shipment, so it shows only what shipped. No credit is needed.
- The lowered qty stays open on the sales order, so it is a backorder by default.

## Decisions
1. **Default: oldest sales-order date first**, ties broken by shipment number. Everyone in line is
   filled in full until the stock runs out.
2. **Supervisor override**: the supervisor can change any customer's allocation on the Invoicing
   screen. That is the only approval needed. Partial fills are allowed; the supervisor decides.
   No whole-case or minimum-qty rules for now.
3. **No customer priority list** for now. Pickup and donation customers get no special treatment.
4. **Unshipped balance stays open on the SO** (backorder). The portal does not write cancels or credits.
5. **Short SKU later = a new shipment on the same load**, with its own invoice, once stock is found.
   Needs a way to create that shipment and add it to the load.
6. **No automatic customer notification** and no trucker check sheet yet. Parked.
7. **Short report** so purchasing, cycle counts and the order desk can see the shorts (SKU, load,
   customers shorted, qty). The order desk reads it in the portal; it is not pushed anywhere.

## Build plan (about 3 to 5 dev days)
1. **Default allocator.** `pDefaults` orders lines by SO order date (needs the date on the
   shipment lines the page loads), then shipment number. Small change, about 0.5 day.
2. **Override with a reason.** A short-reason code on `check_lines` (migration plus UI), and the
   change is logged. About 0.5 day.
3. **Short report.** A view/RPC over `check_lines` where `final_qty < shipped_qty`, plus a page or
   tab, and the HOTLIST cycle-count flag. 1 to 2 days.
4. **Follow-up shipment.** Create a new Acumatica shipment for the short balance and attach it to
   the same load (load number UDF), then run the normal pick, check and invoice. This reuses the
   shipment-request and lock-in paths; scope it before starting. 1 to 2 days.
5. **Later:** customer/rep notification, trucker check sheet.

## Open items
- Check how follow-up shipments reach an already-departed load (it may need a new load number
  suffix, or the same number with a new wave).
- Confirm the SO order date is available from the synced sales-order data.
