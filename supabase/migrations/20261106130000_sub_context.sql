-- 2026-11-06. A substitution flag keeps its own context (Joel).
--
-- Found on L-0611-15: the checker counted 0 of 10003303 and flagged it. Confirm then lowered that line to 0
-- and Acumatica's Confirm Shipment dropped the zero line. The Invoicing worklist reads the item's description from
-- the load's pick list, which only holds lines with a shipped qty, so the row came back as a bare item number
-- ("10003303 10003303"), with nothing to say which customer or SO it was for.
--
-- The flag now carries a snapshot taken when it is raised (and again whenever its note is saved), while the
-- shipment lines are still there:
--   sub_context = { description, uom, required,
--                   lines: [ { shipment, customer_id, customer, order_type, order_nbr, order_line, qty, unit_price } ] }
-- Cleared with the flag (BEFORE UPDATE trigger), so no change is needed to dispatch_check_item.
-- Rollback at the bottom.

alter table public.check_items add column sub_context jsonb;

-- What the load needs of one item and who it is for. Reads the live shipment lines; if confirm has already lowered a
-- line to 0, the checker's own record of what it saw (check_lines.shipped_qty) stands in for the quantity.
create or replace function public._sub_context(p_load_id bigint, p_inventory_id text) returns jsonb
language sql stable security definer set search_path = public as $$
  with l as (select * from loads where id = p_load_id),
  x as (
    select sl.shipment_nbr, sl.line_nbr, sl.description, sl.uom, sl.order_type, sl.order_nbr, sl.order_line_nbr, sl.unit_price,
           coalesce(nullif(cl.shipped_qty, 0), nullif(sl.shipped_qty, 0)) qty,
           s.customer_id, s.customer_name
      from l
      join load_shipments ls on ls.load_id = l.id
      join shipment_lines sl on sl.env = l.env and sl.shipment_nbr = ls.shipment_nbr and sl.inventory_id = p_inventory_id
      left join check_lines cl on cl.load_id = l.id and cl.shipment_nbr = sl.shipment_nbr and cl.line_nbr = sl.line_nbr
      left join lateral (select * from _dispatch_shipments(l.env) z where z.shipment_nbr = ls.shipment_nbr) s on true
  )
  select case when count(*) filter (where qty is not null) = 0 then null else jsonb_build_object(
    'description', max(description), 'uom', max(uom), 'required', sum(qty),
    'lines', jsonb_agg(jsonb_build_object('shipment', shipment_nbr, 'customer_id', customer_id, 'customer', customer_name,
                                         'order_type', order_type, 'order_nbr', order_nbr, 'order_line', order_line_nbr,
                                         'qty', qty, 'unit_price', unit_price) order by shipment_nbr, line_nbr)
               filter (where qty is not null)) end
  from x;
$$;
revoke all on function public._sub_context(bigint, text) from public, anon, authenticated;

-- Same as 20261105210000, plus the snapshot.
create or replace function public.dispatch_check_sub(p_load_id bigint, p_inventory_id text, p_needed boolean, p_note text default null, p_checker text default null)
returns void language plpgsql security definer set search_path = public as $$
declare l loads; req numeric; c check_items; who text := coalesce(nullif(left(btrim(coalesce(p_checker, '')), 60), ''), dispatch_actor_name());
        nt text := left(nullif(btrim(coalesce(p_note, '')), ''), 200); item_desc text;
begin
  perform _dispatch_require('checker');
  select * into l from loads where id = p_load_id for update;
  if not found then raise exception 'Load not found'; end if;
  if l.check_status in ('confirming', 'confirmed') or l.checker_done_at is not null then
    raise exception '% is already checked. Reopen it to change a line.', l.load_nbr; end if;
  select x.required, coalesce(x.description, x.inventory_id) into req, item_desc from dispatch_pick_list(p_load_id) x where x.inventory_id = p_inventory_id;
  if req is null then raise exception 'That item isn''t on this load'; end if;
  select * into c from check_items where load_id = p_load_id and inventory_id = p_inventory_id for update;
  if not found then raise exception 'Enter the checked quantity first (0 if none found)'; end if;
  if p_needed and c.checked_qty >= req then raise exception 'Only a short line can need a substitute'; end if;
  if p_needed then
    update check_items set sub_needed = true, sub_note = nt, sub_by_name = who, sub_at = now(),
           sub_resolved_at = null, sub_resolved_name = null, sub_resolution = null,
           sub_context = _sub_context(p_load_id, p_inventory_id)
     where load_id = p_load_id and inventory_id = p_inventory_id;
    perform _dispatch_log(l, 'sub_flag', item_desc || ' (' || p_inventory_id || '): short ' || (req - c.checked_qty) || coalesce(' · ' || nt, ''));
  else
    update check_items set sub_needed = false, sub_note = null, sub_by_name = null, sub_at = null,
           sub_resolved_at = null, sub_resolved_name = null, sub_resolution = null
     where load_id = p_load_id and inventory_id = p_inventory_id and sub_needed;
    if found then perform _dispatch_log(l, 'sub_unflag', item_desc || ' (' || p_inventory_id || ')'); end if;
  end if;
end $$;

-- The snapshot goes when the flag does (count raised back to full, flag removed).
create or replace function public._check_items_sub_context_clear() returns trigger
language plpgsql set search_path = public as $$
begin
  if not new.sub_needed then new.sub_context := null; end if;
  return new;
end $$;
create trigger check_items_sub_context_clear before update on public.check_items
  for each row execute function public._check_items_sub_context_clear();

-- Flags already raised: rebuild the snapshot from what is still on record.
update public.check_items ci set sub_context = public._sub_context(ci.load_id, ci.inventory_id) where ci.sub_needed;

-- Rollback:
-- drop trigger check_items_sub_context_clear on public.check_items; drop function public._check_items_sub_context_clear();
-- put dispatch_check_sub back to the 20261105210000 version; drop function public._sub_context(bigint, text);
-- alter table public.check_items drop column sub_context;
