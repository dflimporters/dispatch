-- Transfers, picking and checking (go-live 2026-10-12).
--
-- TRANSFERS (read-only suggestion; the portal will write Transfer Orders later)
--   dispatch_transfer_suggest(): per item, open SO demand vs on hand at 71
--   (Molynes, the DC). Where 71 is short and Ashenheim has stock, suggest the
--   shortfall + p_extra_pct, capped at what Ashenheim has. Ashenheim rounds up
--   to pallets itself. Items are full cases, so no case rounding.
--   Source: so_ordered_items (open order lines, refreshed every 5 min, with
--   qty_on_hand_71 / qty_on_hand_ash per item). Assumes SO lines ship from 71.
--
-- PICKING (by load, consolidated: one line per item across the load's shipments)
--   Required qty is live from shipment_lines (not snapshotted), so a corrected
--   shipment shows up straight away. pick_lines holds what was picked;
--   pick_area_status marks each area of a load done.
--   A load can be picked once its trucker is locked in (status done/partial)
--   and until the checker starts confirming it.
--
-- CHECKING (per shipment line)
--   check_lines holds the qty going out on each shipment line. It defaults from
--   the pick (shortages land on the last shipments, which the checker can move)
--   and can only be lowered: additions are a new SO. dispatch-acu check_confirm
--   writes the quantities, sets Control Qty and runs Confirm Shipment.
--   loads.check_status: null -> checking -> confirming -> confirmed | partial.

-- ------------------------------------------------------------------
-- Transfers
-- ------------------------------------------------------------------
create function public.dispatch_transfer_suggest(p_extra_pct numeric default 10, p_days int default 30,
                                                 p_backorders boolean default true)
returns table (inventory_id text, description text, item_class text, orders int, customers int,
               demand numeric, on_hand_71 numeric, on_hand_ash numeric, shortfall numeric,
               suggested numeric, covered boolean, oldest_order date)
language plpgsql stable security definer set search_path = public as $$
begin
  if not dispatch_has_role('batcher') then raise exception 'Your account doesn''t have the coordinator role' using errcode = '42501'; end if;
  return query
  with d as (
    select o.inventory_id, max(o.line_description) description, max(o.item_class) item_class,
           count(distinct o.order_nbr)::int orders, count(distinct o.customer_id)::int customers,
           sum(o.open_qty) demand, max(coalesce(o.qty_on_hand_71, 0)) oh71, max(coalesce(o.qty_on_hand_ash, 0)) ohash,
           min(o.order_date) oldest
      from so_ordered_items o
     where o.order_type = 'SO' and o.open_qty > 0
       and o.order_status in ('Open', 'Back Order', 'Shipping')
       and (p_backorders or o.order_status <> 'Back Order')
       and o.order_date >= current_date - p_days
       and o.inventory_id is not null
     group by o.inventory_id
  )
  select d.inventory_id, d.description, d.item_class, d.orders, d.customers, d.demand, d.oh71, d.ohash,
         d.demand - d.oh71,
         least(d.ohash, ceil((d.demand - d.oh71) * (1 + greatest(p_extra_pct, 0) / 100.0))),
         d.ohash >= d.demand - d.oh71,
         d.oldest
    from d
   where d.demand > d.oh71 and d.ohash > 0
   order by (d.demand - d.oh71) desc;
end $$;
revoke all on function public.dispatch_transfer_suggest(numeric, int, boolean) from public, anon;
grant execute on function public.dispatch_transfer_suggest(numeric, int, boolean) to authenticated;

-- ------------------------------------------------------------------
-- Picking
-- ------------------------------------------------------------------
alter table public.loads add column check_status text
  check (check_status in ('checking', 'confirming', 'confirmed', 'partial'));
alter table public.loads add column checked_by uuid, add column checked_at timestamptz;

create table public.pick_lines (
  load_id      bigint not null references public.loads(id) on delete cascade,
  inventory_id text   not null,
  picked_qty   numeric not null check (picked_qty >= 0),
  note         text,
  picked_by    uuid default auth.uid(),
  picker_name  text,
  picked_at    timestamptz not null default now(),
  primary key (load_id, inventory_id)
);
create table public.pick_area_status (
  load_id    bigint not null references public.loads(id) on delete cascade,
  area       int    not null,              -- 0 = Unassigned
  done_by    uuid default auth.uid(),
  done_name  text,
  done_at    timestamptz not null default now(),
  primary key (load_id, area)
);

-- The load's pick list: one row per item, summed over its shipments' lines.
create function public.dispatch_pick_list(p_load_id bigint)
returns table (inventory_id text, description text, uom text, area int, required numeric, shipments int,
               picked_qty numeric, note text, picker_name text, picked_at timestamptz)
language sql stable security definer set search_path = public as $$
  select sl.inventory_id, max(sl.description), max(sl.uom),
         coalesce(pick_area_of(sl.inventory_id), 0),
         sum(sl.shipped_qty), count(distinct sl.shipment_nbr)::int,
         p.picked_qty, p.note, p.picker_name, p.picked_at
    from loads l
    join load_shipments ls on ls.load_id = l.id
    join shipment_lines sl on sl.env = l.env and sl.shipment_nbr = ls.shipment_nbr
    left join pick_lines p on p.load_id = l.id and p.inventory_id = sl.inventory_id
   where l.id = p_load_id and dispatch_has_role()
     and sl.shipped_qty > 0
   group by sl.inventory_id, p.picked_qty, p.note, p.picker_name, p.picked_at
   order by 4, 2;
$$;

create function public._dispatch_pickable(p_load_id bigint) returns public.loads
language plpgsql security definer set search_path = public as $$
declare l loads;
begin
  select * into l from loads where id = p_load_id for update;
  if not found then raise exception 'Load not found'; end if;
  if l.status not in ('done', 'partial') then raise exception '% has no trucker locked in yet, so it can''t be picked', l.load_nbr; end if;
  if l.check_status in ('confirming', 'confirmed') then raise exception '% has already been checked and confirmed', l.load_nbr; end if;
  return l;
end $$;

create function public.dispatch_pick_set(p_load_id bigint, p_inventory_id text, p_picked numeric, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare l loads;
begin
  perform _dispatch_require('picker');
  l := _dispatch_pickable(p_load_id);
  if p_picked is null then
    delete from pick_lines where load_id = p_load_id and inventory_id = p_inventory_id;
  else
    if p_picked < 0 then raise exception 'Picked quantity can''t be negative'; end if;
    insert into pick_lines (load_id, inventory_id, picked_qty, note, picker_name)
    values (p_load_id, p_inventory_id, p_picked, nullif(trim(p_note), ''), dispatch_actor_name())
    on conflict (load_id, inventory_id) do update
      set picked_qty = excluded.picked_qty, note = excluded.note, picked_by = auth.uid(),
          picker_name = excluded.picker_name, picked_at = now();
  end if;
end $$;

create function public.dispatch_pick_area_done(p_load_id bigint, p_area int, p_done boolean)
returns void language plpgsql security definer set search_path = public as $$
declare l loads; missing int;
begin
  perform _dispatch_require('picker');
  l := _dispatch_pickable(p_load_id);
  if p_done then
    select count(*) into missing from dispatch_pick_list(p_load_id) x where x.area = p_area and x.picked_qty is null;
    if missing > 0 then raise exception '% item(s) in this area have no picked quantity yet', missing; end if;
    insert into pick_area_status (load_id, area, done_name) values (p_load_id, p_area, dispatch_actor_name())
    on conflict (load_id, area) do update set done_by = auth.uid(), done_name = excluded.done_name, done_at = now();
    perform _dispatch_log(l, 'pick_done', 'Area ' || case when p_area = 0 then 'unassigned' else p_area::text end || ' picked');
  else
    delete from pick_area_status where load_id = p_load_id and area = p_area;
    perform _dispatch_log(l, 'pick_reopen', 'Area ' || case when p_area = 0 then 'unassigned' else p_area::text end || ' reopened');
  end if;
end $$;

-- ------------------------------------------------------------------
-- Checking
-- ------------------------------------------------------------------
create table public.check_lines (
  load_id      bigint not null references public.loads(id) on delete cascade,
  shipment_nbr text   not null,
  line_nbr     int    not null,
  inventory_id text,
  shipped_qty  numeric not null,           -- on the shipment when the check was saved
  final_qty    numeric not null check (final_qty >= 0),
  primary key (load_id, shipment_nbr, line_nbr)
);
alter table public.load_shipments add column check_result text check (check_result in ('applied', 'refused', 'failed'));
alter table public.load_shipments add column check_detail text, add column check_at timestamptz;

-- Save the checker's quantities: [{shipment_nbr, line_nbr, final_qty}].
-- Only lowering is allowed; the shipment's current qty is the ceiling.
create function public.dispatch_check_save(p_load_id bigint, p_lines jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare l loads; bad text;
begin
  perform _dispatch_require('checker');
  select * into l from loads where id = p_load_id for update;
  if not found then raise exception 'Load not found'; end if;
  if l.status not in ('done', 'partial') then raise exception '% has no trucker locked in yet', l.load_nbr; end if;
  if l.check_status in ('confirming', 'confirmed') then raise exception '% is already being confirmed or confirmed', l.load_nbr; end if;

  with x as (select r->>'shipment_nbr' nbr, (r->>'line_nbr')::int ln, (r->>'final_qty')::numeric q from jsonb_array_elements(p_lines) r)
  select string_agg(x.nbr || '/' || x.ln, ', ') into bad
    from x
    left join load_shipments ls on ls.load_id = p_load_id and ls.shipment_nbr = x.nbr
    left join shipment_lines sl on sl.env = l.env and sl.shipment_nbr = x.nbr and sl.line_nbr = x.ln
   where ls.shipment_nbr is null or sl.line_nbr is null or x.q < 0 or x.q > sl.shipped_qty;
  if bad is not null then raise exception 'Quantities can only be lowered, on lines of this load: %', bad; end if;

  delete from check_lines where load_id = p_load_id;
  insert into check_lines (load_id, shipment_nbr, line_nbr, inventory_id, shipped_qty, final_qty)
  select p_load_id, x.nbr, x.ln, sl.inventory_id, sl.shipped_qty, x.q
    from (select r->>'shipment_nbr' nbr, (r->>'line_nbr')::int ln, (r->>'final_qty')::numeric q from jsonb_array_elements(p_lines) r) x
    join shipment_lines sl on sl.env = l.env and sl.shipment_nbr = x.nbr and sl.line_nbr = x.ln;
  update loads set check_status = 'checking', checked_by = auth.uid(), checked_at = now() where id = p_load_id;
  perform _dispatch_log(l, 'check_save', (select count(*) from check_lines where load_id = p_load_id and final_qty < shipped_qty) || ' line(s) lowered');
end $$;

-- ------------------------------------------------------------------
-- RLS + grants
-- ------------------------------------------------------------------
alter table public.pick_lines       enable row level security;
alter table public.pick_area_status enable row level security;
alter table public.check_lines      enable row level security;
create policy pick_lines_read       on public.pick_lines       for select to authenticated using (public.dispatch_has_role());
create policy pick_area_status_read on public.pick_area_status for select to authenticated using (public.dispatch_has_role());
create policy check_lines_read      on public.check_lines      for select to authenticated using (public.dispatch_has_role());
revoke all on public.pick_lines, public.pick_area_status, public.check_lines from anon;
revoke insert, update, delete, truncate on public.pick_lines, public.pick_area_status, public.check_lines from authenticated;

revoke all on function public._dispatch_pickable(bigint) from public, anon, authenticated;
revoke all on function public.dispatch_pick_list(bigint) from public, anon;
revoke all on function public.dispatch_pick_set(bigint, text, numeric, text) from public, anon;
revoke all on function public.dispatch_pick_area_done(bigint, int, boolean) from public, anon;
revoke all on function public.dispatch_check_save(bigint, jsonb) from public, anon;
grant execute on function public.dispatch_pick_list(bigint) to authenticated;
grant execute on function public.dispatch_pick_set(bigint, text, numeric, text) to authenticated;
grant execute on function public.dispatch_pick_area_done(bigint, int, boolean) to authenticated;
grant execute on function public.dispatch_check_save(bigint, jsonb) to authenticated;
