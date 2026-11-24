-- 2026-11-23 (Joel). L-2311-25: a supervisor deleted shipment 286019 (SO 210319) in Acumatica after the goods were
-- picked and checked. Nothing told anyone: the checker kept 46 Bingo Hand Towel, the check-off sheet printed 17, and
-- the trucker left with 46 cases. The sync removes a deleted shipment from `shipments`, but its lines stay in
-- `shipment_lines` and `load_shipments` keeps pointing at it, so the pick list went on counting it.
--
-- 1. Detect: _flag_gone_shipments() (cron, every minute) finds shipments on a recent live load that have vanished from
--    `shipments` (twice, 4+ minutes apart, and only while the shipment sync is fresh, so a sync hiccup can't flag one).
--    It snapshots what was on it (item, qty, what the picker and checker had recorded) into load_gone_shipments,
--    logs 'shipment_gone' on the load, marks the printed sheet stale, and stops the pick list counting it.
-- 2. Guard: the picker, checker, Invoicing and sheet pages show the snapshot as a banner ("take 29 off the truck").
--    A trigger refuses to queue Confirm for the load until a supervisor acknowledges each one with
--    dispatch_gone_ack(), which also takes the shipment off the load.
-- 5. Reconcile: the checker's and picker's saved quantities are capped to what the load still needs (the count at the
--    time is kept in the snapshot), and lm_check_sheet returns 'gone' and 'recon' (items where the sheet's total
--    differs from the checker's count) so the sheet page can warn before it is printed.
--
-- Live env only (the TEST mirror is refilled by hand, so a missing shipment there means nothing).
-- Rollback at the bottom.

create table public.load_gone_shipments (
  id            bigint generated always as identity primary key,
  env           text   not null default 'live',
  load_id       bigint not null references public.loads(id) on delete cascade,
  shipment_nbr  text   not null,
  order_nbr     text,
  customer_name text,
  -- [{inventory_id, description, uom, qty, picked, counted}]: qty = what the shipment had, picked/counted = what the
  -- picker / checker had recorded for that item on the load at the time (null = not done yet)
  lines         jsonb  not null default '[]'::jsonb,
  touched       boolean not null default false,   -- something on it was already picked or checked
  flagged_at    timestamptz not null default now(),
  ack_at        timestamptz,
  ack_by        uuid,
  ack_name      text,
  ack_note      text,
  unique (load_id, shipment_nbr)
);
create index load_gone_open on public.load_gone_shipments (load_id) where ack_at is null;
alter table public.load_gone_shipments enable row level security;
create policy load_gone_read on public.load_gone_shipments for select to authenticated using (public.dispatch_has_role());
revoke all on public.load_gone_shipments from public, anon;
grant select on public.load_gone_shipments to authenticated;

create table public.gone_pending (
  env          text not null,
  shipment_nbr text not null,
  first_seen   timestamptz not null default now(),
  primary key (env, shipment_nbr)
);
alter table public.gone_pending enable row level security;
revoke all on public.gone_pending from public, anon, authenticated;

-- What a load still needs of an item, leaving out shipments flagged as gone.
create function public._load_remaining(p_load_id bigint, p_inventory_id text) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(sl.shipped_qty), 0)
    from load_shipments ls
    join shipment_lines sl on sl.env = ls.env and sl.shipment_nbr = ls.shipment_nbr
   where ls.load_id = p_load_id and sl.inventory_id = p_inventory_id and sl.shipped_qty > 0
     and not exists (select 1 from load_gone_shipments g where g.load_id = ls.load_id and g.shipment_nbr = ls.shipment_nbr);
$$;
revoke all on function public._load_remaining(bigint, text) from public, anon, authenticated;

create function public._flag_gone_shipments() returns int
language plpgsql security definer set search_path = public as $$
declare r record; l loads; n int := 0; v_lines jsonb; v_ord text; v_cust text; v_touched boolean; v_fresh timestamptz;
begin
  select max(synced_at) into v_fresh from shipments;
  if v_fresh is null or v_fresh < now() - interval '30 minutes' then return 0; end if;   -- sync not running: nothing can have changed

  delete from gone_pending p where exists (select 1 from shipments s where s.shipment_nbr = p.shipment_nbr)
                                or not exists (select 1 from load_shipments ls where ls.env = p.env and ls.shipment_nbr = p.shipment_nbr);
  -- back in Acumatica before anyone dealt with it: drop the flag
  delete from load_gone_shipments g where g.ack_at is null and exists (select 1 from shipments s where s.shipment_nbr = g.shipment_nbr);

  insert into gone_pending (env, shipment_nbr)
  select ls.env, ls.shipment_nbr
    from load_shipments ls join loads l on l.id = ls.load_id
   where ls.env = 'live' and l.load_date >= current_date - 1 and coalesce(l.check_status, '') <> 'confirmed'
     and not exists (select 1 from shipments s where s.shipment_nbr = ls.shipment_nbr)
  on conflict do nothing;

  for r in
    select ls.load_id, ls.shipment_nbr
      from load_shipments ls
      join gone_pending p on p.env = ls.env and p.shipment_nbr = ls.shipment_nbr
     where ls.env = 'live' and p.first_seen < now() - interval '4 minutes'
       and not exists (select 1 from shipments s where s.shipment_nbr = ls.shipment_nbr)
       and not exists (select 1 from load_gone_shipments g where g.load_id = ls.load_id and g.shipment_nbr = ls.shipment_nbr)
  loop
    select * into l from loads where id = r.load_id for update;
    if not found then continue; end if;
    select max(order_nbr) into v_ord from shipment_lines where env = 'live' and shipment_nbr = r.shipment_nbr;
    select customer_name into v_cust from sales_orders where order_nbr = v_ord limit 1;
    select coalesce(jsonb_agg(jsonb_build_object('inventory_id', x.inventory_id, 'description', x.description, 'uom', x.uom,
                                                 'qty', x.qty, 'picked', pl.picked_qty, 'counted', ci.checked_qty) order by x.inventory_id), '[]'::jsonb)
      into v_lines
      from (select inventory_id, max(description) description, max(uom) uom, sum(shipped_qty) qty
              from shipment_lines where env = 'live' and shipment_nbr = r.shipment_nbr and shipped_qty > 0 group by inventory_id) x
      left join pick_lines  pl on pl.load_id = l.id and pl.inventory_id = x.inventory_id
      left join check_items ci on ci.load_id = l.id and ci.inventory_id = x.inventory_id;
    v_touched := exists (select 1 from jsonb_array_elements(v_lines) e where e->>'picked' is not null or e->>'counted' is not null);

    insert into load_gone_shipments (env, load_id, shipment_nbr, order_nbr, customer_name, lines, touched)
    values ('live', l.id, r.shipment_nbr, v_ord, v_cust, v_lines, v_touched);

    -- the picker's and checker's saved numbers can't exceed what the load still needs
    update check_items c set checked_qty = least(c.checked_qty, _load_remaining(c.load_id, c.inventory_id))
     where c.load_id = l.id and c.inventory_id in (select e->>'inventory_id' from jsonb_array_elements(v_lines) e)
       and c.checked_qty > _load_remaining(c.load_id, c.inventory_id);
    update pick_lines p set picked_qty = least(p.picked_qty, _load_remaining(p.load_id, p.inventory_id))
     where p.load_id = l.id and p.inventory_id in (select e->>'inventory_id' from jsonb_array_elements(v_lines) e)
       and p.picked_qty > _load_remaining(p.load_id, p.inventory_id);

    update loads set sheet_stale_at = now() where id = l.id;
    perform _dispatch_log(l, 'shipment_gone',
      'Shipment ' || r.shipment_nbr || coalesce(' (SO ' || v_ord || coalesce(', ' || v_cust, '') || ')', '')
        || ' was deleted in Acumatica' || case when v_touched then ' after picking/checking started: goods may need to come off the truck' else '' end,
      jsonb_build_object('shipment', r.shipment_nbr, 'order', v_ord, 'touched', v_touched, 'lines', v_lines));
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public._flag_gone_shipments() from public, anon, authenticated;

select cron.schedule('dispatch-gone-shipments-1min', '* * * * *', $cron$ select public._flag_gone_shipments() $cron$);

-- A supervisor says the goods are dealt with (back in stock, off the truck, or re-shipped) and takes it off the load.
create function public.dispatch_gone_ack(p_load_id bigint, p_shipment_nbr text, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare g load_gone_shipments; l loads; nt text := left(nullif(btrim(coalesce(p_note, '')), ''), 300);
begin
  if auth.uid() is null or not (dispatch_has_role('supervisor') or dispatch_has_role('manager') or dispatch_has_role('admin')) then
    raise exception 'Only a supervisor can clear this' using errcode = '42501'; end if;
  if nt is null or length(nt) < 3 then raise exception 'Say what happened to the goods (returned to stock, off the truck...)'; end if;
  select * into l from loads where id = p_load_id for update;
  if not found then raise exception 'Load not found'; end if;
  select * into g from load_gone_shipments where load_id = p_load_id and shipment_nbr = p_shipment_nbr and ack_at is null for update;
  if not found then raise exception 'Nothing to clear for shipment %', p_shipment_nbr; end if;
  update load_gone_shipments set ack_at = now(), ack_by = auth.uid(), ack_name = dispatch_actor_name(), ack_note = nt where id = g.id;
  delete from load_shipments where load_id = p_load_id and shipment_nbr = p_shipment_nbr;
  update loads set sheet_stale_at = now() where id = p_load_id;
  perform _dispatch_log(l, 'gone_ack', 'Shipment ' || p_shipment_nbr || ' taken off the load: ' || nt,
                        jsonb_build_object('shipment', p_shipment_nbr, 'order', g.order_nbr));
end $$;
revoke all on function public.dispatch_gone_ack(bigint, text, text) from public, anon;
grant execute on function public.dispatch_gone_ack(bigint, text, text) to authenticated;

-- Confirm can't be queued while one is open. (dispatch-acu sets confirm_requested_at directly; the error text comes back to the page.)
create function public._block_confirm_gone() returns trigger language plpgsql security definer set search_path = public as $$
declare g load_gone_shipments;
begin
  if new.confirm_requested_at is not null and old.confirm_requested_at is null then
    select * into g from load_gone_shipments where load_id = new.id and ack_at is null order by flagged_at limit 1;
    if found then
      raise exception '% has shipment % (SO %) deleted in Acumatica. A supervisor must clear it first (the Invoicing page shows what to take off the truck).',
        new.load_nbr, g.shipment_nbr, coalesce(g.order_nbr, '?');
    end if;
  end if;
  return new;
end $$;
create trigger loads_block_confirm_gone before update of confirm_requested_at on public.loads
  for each row execute function public._block_confirm_gone();

-- The pick list (and so the picker and checker) no longer counts a flagged shipment.
create or replace function public.dispatch_pick_list(p_load_id bigint)
returns table(inventory_id text, description text, uom text, area integer, required numeric, shipments integer, picked_qty numeric, note text, picker_name text, picked_at timestamptz)
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
     and not exists (select 1 from load_gone_shipments g where g.load_id = l.id and g.shipment_nbr = ls.shipment_nbr)
   group by sl.inventory_id, p.picked_qty, p.note, p.picker_name, p.picked_at
   order by 4, 2;
$$;

-- The bundle: customers leave out flagged shipments, and 'gone' carries the open ones for the banners.
create or replace function public.dispatch_pick_bundle(p_load_ids bigint[], p_with_checks boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not dispatch_has_role() then raise exception 'Your account has no dispatch role' using errcode = '42501'; end if;
  return jsonb_build_object(
    'picks',  coalesce((select jsonb_agg(to_jsonb(x) || jsonb_build_object('load_id', l.id))
                          from unnest(p_load_ids) as l(id), lateral dispatch_pick_list(l.id) x), '[]'::jsonb),
    'done',   coalesce((select jsonb_agg(to_jsonb(s)) from pick_area_status s where s.load_id = any(p_load_ids)), '[]'::jsonb),
    'staged', coalesce((select jsonb_agg(to_jsonb(s)) from stage_area_status s where s.load_id = any(p_load_ids)), '[]'::jsonb),
    'checks', case when p_with_checks
                   then coalesce((select jsonb_agg(to_jsonb(c)) from check_lines c where c.load_id = any(p_load_ids)), '[]'::jsonb)
                   else '[]'::jsonb end,
    'items',  case when p_with_checks
                   then coalesce((select jsonb_agg(to_jsonb(c)) from check_items c where c.load_id = any(p_load_ids)), '[]'::jsonb)
                   else '[]'::jsonb end,
    'customers', coalesce((
        select jsonb_agg(jsonb_build_object('load_id', t.load_id, 'inventory_id', t.inventory_id, 'list', t.list))
          from (select c.load_id, c.inventory_id,
                       jsonb_agg(jsonb_build_object('name', c.name, 'qty', c.qty) order by c.name) as list
                  from (select l.id as load_id, sl.inventory_id,
                               coalesce(max(s.customer_name), max(s.customer_id), '?') as name, sum(sl.shipped_qty) as qty
                          from loads l
                          join load_shipments ls on ls.load_id = l.id
                          join shipment_lines sl on sl.env = l.env and sl.shipment_nbr = ls.shipment_nbr and sl.shipped_qty > 0
                          left join _dispatch_shipments(l.env) s on s.shipment_nbr = ls.shipment_nbr
                         where l.id = any(p_load_ids)
                           and not exists (select 1 from load_gone_shipments g where g.load_id = l.id and g.shipment_nbr = ls.shipment_nbr)
                         group by l.id, sl.inventory_id, coalesce(s.customer_id, s.customer_name, ls.shipment_nbr)) c
                 group by c.load_id, c.inventory_id) t), '[]'::jsonb),
    'gone', coalesce((select jsonb_agg(jsonb_build_object('load_id', g.load_id, 'shipment_nbr', g.shipment_nbr, 'order_nbr', g.order_nbr,
                                                           'customer_name', g.customer_name, 'lines', g.lines, 'touched', g.touched,
                                                           'flagged_at', g.flagged_at) order by g.flagged_at)
                        from load_gone_shipments g where g.load_id = any(p_load_ids) and g.ack_at is null), '[]'::jsonb));
end $$;

-- lm_check_sheet: adds 'gone' (open flags) and 'recon' (items where the sheet's total isn't the checker's count);
-- otherwise as in 20261111120000_sheets_real_invoice_numbers.sql.
create or replace function public.lm_check_sheet(p_load_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l loads;
begin
  if auth.uid() is null or not dispatch_has_role() then
    raise exception 'Your account doesn''t have a dispatch role' using errcode = '42501';
  end if;
  select * into l from loads where id = p_load_id;
  if not found then raise exception 'Load not found'; end if;
  return jsonb_build_object(
    'load_nbr', l.load_nbr, 'load_date', l.load_date, 'wave', l.wave, 'env', l.env,
    'ship_via', l.ship_via, 'trucker', (select description from ship_via_codes where ship_via = l.ship_via),
    'truck_type', l.truck_type, 'check_status', l.check_status,
    'gone', coalesce((select jsonb_agg(jsonb_build_object('shipment_nbr', g.shipment_nbr, 'order_nbr', g.order_nbr,
                                                           'customer_name', g.customer_name, 'lines', g.lines, 'touched', g.touched) order by g.flagged_at)
                        from load_gone_shipments g where g.load_id = l.id and g.ack_at is null), '[]'::jsonb),
    'recon', coalesce((
      select jsonb_agg(jsonb_build_object('inventory_id', t.inv, 'description', t.descr, 'uom', t.u, 'sheet', t.sheet, 'counted', t.counted) order by t.inv)
        from (select ci.inventory_id inv, max(sl.description) descr, max(sl.uom) u,
                     sum(coalesce(cl.final_qty, sl.shipped_qty)) sheet, max(ci.checked_qty) counted
                from check_items ci
                join load_shipments ls on ls.load_id = l.id
                join shipment_lines sl on sl.env = l.env and sl.shipment_nbr = ls.shipment_nbr and sl.inventory_id = ci.inventory_id
                left join check_lines cl on cl.load_id = l.id and cl.shipment_nbr = sl.shipment_nbr and cl.line_nbr = sl.line_nbr
               where ci.load_id = l.id and ci.checked_qty is not null
                 and exists (select 1 from _dispatch_shipments(l.env) s where s.shipment_nbr = ls.shipment_nbr)
                 and not exists (select 1 from load_gone_shipments g where g.load_id = l.id and g.shipment_nbr = ls.shipment_nbr)
               group by ci.inventory_id
              having sum(coalesce(cl.final_qty, sl.shipped_qty)) <> max(ci.checked_qty)) t), '[]'::jsonb),
    'farthest', (select jsonb_build_object('zone', d.zone, 'label', d.label, 'km', d.km)
                   from _lm_stop_rows(p_load_id) r join zone_distance d on d.zone = upper(btrim(r.zone))
                  order by d.km desc, d.zone limit 1),
    'stops', coalesce((
      select jsonb_agg(jsonb_build_object(
               'seq', r.seq, 'customer_id', r.customer_id, 'customer_name', r.customer_name,
               'address', r.address, 'city', r.city, 'phone', r.phone, 'zone', r.zone,
               'shipments', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'shipment_nbr', ls.shipment_nbr,
                          'invoice_nbr', coalesce(
                              (select i.invoice_nbr from lm_stop_invoices i join lm_stops st on st.id = i.stop_id
                                where st.load_id = l.id and i.shipment_nbr = ls.shipment_nbr and i.invoice_nbr is not null limit 1),
                              _lm_invoice_nbrs(ls.shipment_nbr, l.load_date)),
                          'lines', (select coalesce(jsonb_agg(jsonb_build_object(
                                             'line_nbr', sl.line_nbr, 'inventory_id', sl.inventory_id, 'description', sl.description,
                                             'uom', sl.uom, 'qty', coalesce(cl.final_qty, sl.shipped_qty)) order by sl.line_nbr), '[]'::jsonb)
                                      from shipment_lines sl
                                      left join check_lines cl on cl.load_id = l.id and cl.shipment_nbr = sl.shipment_nbr and cl.line_nbr = sl.line_nbr
                                     where sl.env = l.env and sl.shipment_nbr = ls.shipment_nbr
                                       and coalesce(cl.final_qty, sl.shipped_qty) > 0)
                        ) order by ls.shipment_nbr), '[]'::jsonb)
                   from load_shipments ls
                   join lateral (select * from _dispatch_shipments(l.env) x where x.shipment_nbr = ls.shipment_nbr) s on true
                  where ls.load_id = l.id and coalesce(s.customer_id, '?') = r.customer_id))
             order by r.seq)
        from _lm_stop_rows(p_load_id) r), '[]'::jsonb));
end $$;

revoke all on function public.lm_check_sheet(bigint) from public, anon;
grant execute on function public.lm_check_sheet(bigint) to authenticated;

-- Rollback (by hand): select cron.unschedule('dispatch-gone-shipments-1min');
--   drop trigger loads_block_confirm_gone on public.loads; drop function public._block_confirm_gone();
--   restore dispatch_pick_list from 20261007130000_transfers_picking_checking.sql (or the live definition without the
--   load_gone_shipments filter), dispatch_pick_bundle from 20261123130000_pick_bundle_customers.sql and lm_check_sheet from
--   20261111120000_sheets_real_invoice_numbers.sql;
--   drop function public.dispatch_gone_ack(bigint, text, text), public._flag_gone_shipments(), public._load_remaining(bigint, text);
--   drop table public.load_gone_shipments, public.gone_pending;
