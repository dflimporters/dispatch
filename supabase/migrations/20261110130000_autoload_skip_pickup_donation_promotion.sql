-- Auto-loads never take pickup / donation / promotion shipments (Joel, 2026-11-10).
--
-- dispatch_autoload_sync() turned any Open/On Hold shipment with a Ship Via into an ACU load. Pickup,
-- donation and promotion shipments are handled separately (batchers load them on the portal), so the
-- sync now skips: a PICKUP* Ship Via, or a customer whose kind (dispatch_customer_kinds) is
-- pickup / donation / promotion. Same rule as kindOf() in common.js. 'office' is not excluded.
--
-- Patches the live function body in place (one extra condition in step 2), so nothing else in it
-- can drift from what is deployed. Shipments already on an auto-load stay where they are.

do $$
declare
  src text := pg_get_functiondef('public.dispatch_autoload_sync(text)'::regprocedure);
  dst text;
begin
  dst := replace(src,
    $a$       and s.ship_via not ilike 'BATCH%'
$a$,
    $b$       and s.ship_via not ilike 'BATCH%'
       and s.ship_via not ilike 'PICKUP%'
       and not exists (select 1 from dispatch_customer_kinds() k
                        where k.customer_id = s.customer_id and k.kind in ('pickup', 'donation', 'promotion'))
$b$);
  if dst = src then raise exception 'autoload sync: expected line not found, nothing changed'; end if;
  execute dst;
end $$;
