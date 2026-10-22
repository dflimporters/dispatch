-- 2026-10-22, after the Ops walkthrough.
--
-- 1. Stop shipment values flipping back to 0. The 5-minute live line sync writes null prices
--    (and a 0 value) for orders it fails to price; dispatch_reprice_live() fixes that every
--    minute, but the next sync undid it. A price already on a line is now never replaced by
--    null, and dispatch_set_values never replaces a positive value with 0.
-- 2. Truck type "3 Ton" (capacity 300).
-- 3. Staging, per area: after an area is picked, someone marks it staged.
-- 4. Checker substitution notes: a reason on any line the checker lowers.

-- 1 --------------------------------------------------------------------
create or replace function public.shipment_lines_keep_price() returns trigger
language plpgsql as $$
begin
  if new.unit_price is null and old.unit_price is not null
     and new.order_nbr is not distinct from old.order_nbr
     and new.order_line_nbr is not distinct from old.order_line_nbr then
    new.unit_price := old.unit_price;
    new.line_value := round(coalesce(new.shipped_qty, 0) * old.unit_price, 2);
  end if;
  return new;
end $$;
drop trigger if exists shipment_lines_keep_price on public.shipment_lines;
create trigger shipment_lines_keep_price before update on public.shipment_lines
  for each row execute function public.shipment_lines_keep_price();

create or replace function public.dispatch_set_values(p_rows jsonb) returns int
language sql security definer set search_path = public as $$
  with r as (select x->>'shipment_nbr' nbr, (x->>'value')::numeric val from jsonb_array_elements(p_rows) x),
       u as (update shipments s set shipment_value = r.val from r
              where s.shipment_nbr = r.nbr and not (coalesce(r.val, 0) = 0 and coalesce(s.shipment_value, 0) > 0)
              returning 1)
  select count(*)::int from u;
$$;

-- 2 --------------------------------------------------------------------
update public.truck_types set sort_order = sort_order + 1 where sort_order >= 2;
insert into public.truck_types (name, capacity_volume, sort_order, active) values ('3 Ton', 300, 2, true);

-- 3 --------------------------------------------------------------------
create table public.stage_area_status (
  load_id     bigint not null references public.loads(id) on delete cascade,
  area        int    not null,
  staged_by   uuid default auth.uid(),
  staged_name text,
  staged_at   timestamptz not null default now(),
  primary key (load_id, area)
);
alter table public.stage_area_status enable row level security;
create policy stage_area_status_read on public.stage_area_status for select to authenticated using (public.dispatch_has_role());
revoke all on public.stage_area_status from anon;
revoke insert, update, delete, truncate on public.stage_area_status from authenticated;

create function public.dispatch_stage_area(p_load_id bigint, p_area int, p_staged boolean)
returns void language plpgsql security definer set search_path = public as $$
declare l loads; nm text := case when p_area = 0 then 'unassigned' else p_area::text end;
begin
  perform _dispatch_require('picker');
  l := _dispatch_pickable(p_load_id);
  if p_staged then
    if not exists (select 1 from pick_area_status where load_id = p_load_id and area = p_area) then
      raise exception 'Finish picking area % before staging it', nm;
    end if;
    insert into stage_area_status (load_id, area, staged_name) values (p_load_id, p_area, dispatch_actor_name())
    on conflict (load_id, area) do update set staged_by = auth.uid(), staged_name = excluded.staged_name, staged_at = now();
    perform _dispatch_log(l, 'stage_done', 'Area ' || nm || ' staged');
  else
    delete from stage_area_status where load_id = p_load_id and area = p_area;
    perform _dispatch_log(l, 'stage_reopen', 'Area ' || nm || ' unstaged');
  end if;
end $$;
revoke all on function public.dispatch_stage_area(bigint, int, boolean) from public, anon;
grant execute on function public.dispatch_stage_area(bigint, int, boolean) to authenticated;

-- Reopening a picked area also un-stages it.
create or replace function public.dispatch_pick_area_done(p_load_id bigint, p_area int, p_done boolean)
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
    delete from stage_area_status where load_id = p_load_id and area = p_area;
    perform _dispatch_log(l, 'pick_reopen', 'Area ' || case when p_area = 0 then 'unassigned' else p_area::text end || ' reopened');
  end if;
end $$;

-- 4 --------------------------------------------------------------------
alter table public.check_lines add column note text;

-- Same as before, plus an optional "note" per line (why it was lowered / what replaced it).
create or replace function public.dispatch_check_save(p_load_id bigint, p_lines jsonb)
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
  insert into check_lines (load_id, shipment_nbr, line_nbr, inventory_id, shipped_qty, final_qty, note)
  select p_load_id, x.nbr, x.ln, sl.inventory_id, sl.shipped_qty, x.q,
         case when x.q < sl.shipped_qty then left(nullif(trim(x.note), ''), 200) end
    from (select r->>'shipment_nbr' nbr, (r->>'line_nbr')::int ln, (r->>'final_qty')::numeric q, r->>'note' note
            from jsonb_array_elements(p_lines) r) x
    join shipment_lines sl on sl.env = l.env and sl.shipment_nbr = x.nbr and sl.line_nbr = x.ln;
  update loads set check_status = 'checking', checked_by = auth.uid(), checked_at = now() where id = p_load_id;
  perform _dispatch_log(l, 'check_save', (select count(*) from check_lines where load_id = p_load_id and final_qty < shipped_qty) || ' line(s) lowered',
    (select jsonb_build_object('notes', coalesce(jsonb_agg(jsonb_build_object('shipment', shipment_nbr, 'item', inventory_id, 'note', note)), '[]'::jsonb))
       from check_lines where load_id = p_load_id and note is not null));
end $$;
