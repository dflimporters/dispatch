-- Checker works per SKU; Invoicing writes to Acumatica (Joel, 2026-10-24).
--
-- Before: the checker set a "going out" figure per customer line and confirmed the load in
-- Acumatica. Now:
--   * The checker counts each SKU on the load (picking-sheet layout, by area): a checked figure
--     and a tick per line (check_items). Finishing the check (dispatch_check_finish) marks the
--     load checker_done_at and hands it to Invoicing. Nothing is written to Acumatica.
--   * Invoicing (supervisor role) splits any short SKU over the customers, saves it
--     (dispatch_check_save, now supervisor + only after the checker has finished) and confirms
--     the load in Acumatica (dispatch-acu check_confirm, now supervisor).
--   * loads.check_status keeps its meaning (null -> checking -> confirming -> confirmed | partial);
--     loads.checker_done_at says the checker has finished. 'checking' is set when the checker
--     finishes, so the existing queue (which looks for 'checking' / 'partial') picks it up.
--
-- Rollback at the bottom.

alter table public.loads add column checker_done_at timestamptz, add column checker_done_by uuid, add column checker_done_name text;

create table public.check_items (
  load_id      bigint not null references public.loads(id) on delete cascade,
  inventory_id text   not null,
  checked_qty  numeric check (checked_qty >= 0),
  confirmed    boolean not null default false,
  checked_by   uuid default auth.uid(),
  checker_name text,
  checked_at   timestamptz not null default now(),
  primary key (load_id, inventory_id)
);
alter table public.check_items enable row level security;
create policy check_items_read on public.check_items for select to authenticated using (public.dispatch_has_role());

-- A finished check locks picking too.
create or replace function public._dispatch_pickable(p_load_id bigint) returns public.loads
language plpgsql security definer set search_path = public as $$
declare l loads;
begin
  select * into l from loads where id = p_load_id for update;
  if not found then raise exception 'Load not found'; end if;
  if l.status not in ('done', 'partial') then raise exception '% has no trucker locked in yet, so it can''t be picked', l.load_nbr; end if;
  if l.check_status in ('confirming', 'confirmed') or l.checker_done_at is not null then
    raise exception '% has already been checked', l.load_nbr; end if;
  return l;
end $$;

-- One SKU: the checker's figure and whether the line is ticked. qty null + unticked clears it.
create function public.dispatch_check_item(p_load_id bigint, p_inventory_id text, p_qty numeric, p_confirmed boolean)
returns void language plpgsql security definer set search_path = public as $$
declare l loads; req numeric;
begin
  perform _dispatch_require('checker');
  select * into l from loads where id = p_load_id for update;
  if not found then raise exception 'Load not found'; end if;
  if l.status not in ('done', 'partial') then raise exception '% has no trucker locked in yet', l.load_nbr; end if;
  if l.check_status in ('confirming', 'confirmed') or l.checker_done_at is not null then
    raise exception '% is already checked. Reopen it to change a line.', l.load_nbr; end if;
  select x.required into req from dispatch_pick_list(p_load_id) x where x.inventory_id = p_inventory_id;
  if req is null then raise exception 'That item isn''t on this load'; end if;
  if p_qty is not null and (p_qty < 0 or p_qty > req) then
    raise exception 'Checked quantity must be between 0 and % (what the load needs)', req; end if;
  if p_confirmed and p_qty is null then raise exception 'Enter the checked quantity before ticking the line'; end if;
  if p_qty is null then
    delete from check_items where load_id = p_load_id and inventory_id = p_inventory_id;
  else
    insert into check_items (load_id, inventory_id, checked_qty, confirmed, checker_name)
    values (p_load_id, p_inventory_id, p_qty, p_confirmed, dispatch_actor_name())
    on conflict (load_id, inventory_id) do update
      set checked_qty = excluded.checked_qty, confirmed = excluded.confirmed, checked_by = auth.uid(),
          checker_name = excluded.checker_name, checked_at = now();
  end if;
end $$;

-- The checker is done: every SKU on the load must be ticked. Hands the load to Invoicing.
create function public.dispatch_check_finish(p_load_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare l loads; open_n int; short_n int;
begin
  perform _dispatch_require('checker');
  select * into l from loads where id = p_load_id for update;
  if not found then raise exception 'Load not found'; end if;
  if l.check_status in ('confirming', 'confirmed') or l.checker_done_at is not null then
    raise exception '% is already checked', l.load_nbr; end if;
  select count(*) into open_n from dispatch_pick_list(p_load_id) x
   where not exists (select 1 from check_items c where c.load_id = p_load_id and c.inventory_id = x.inventory_id and c.confirmed);
  if open_n > 0 then raise exception '% line(s) still to check', open_n; end if;
  select count(*) into short_n from dispatch_pick_list(p_load_id) x
    join check_items c on c.load_id = p_load_id and c.inventory_id = x.inventory_id where c.checked_qty < x.required;
  update loads set checker_done_at = now(), checker_done_by = auth.uid(), checker_done_name = dispatch_actor_name(),
                   check_status = coalesce(check_status, 'checking'), checked_by = auth.uid(), checked_at = now()
   where id = p_load_id;
  perform _dispatch_log(l, 'check_done', short_n || ' item(s) short');
end $$;

-- Back to the checker, as long as Invoicing hasn't started confirming it.
create function public.dispatch_check_reopen(p_load_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare l loads;
begin
  if not (dispatch_has_role('checker') or dispatch_has_role('supervisor')) then
    raise exception 'Your account can''t reopen a check' using errcode = '42501'; end if;
  select * into l from loads where id = p_load_id for update;
  if not found then raise exception 'Load not found'; end if;
  if l.checker_done_at is null then return; end if;
  if l.check_status in ('confirming', 'confirmed', 'partial') or l.confirm_requested_at is not null then
    raise exception '% is already with Acumatica', l.load_nbr; end if;
  update loads set checker_done_at = null, checker_done_by = null, checker_done_name = null, check_status = null where id = p_load_id;
  delete from check_lines where load_id = p_load_id;
  perform _dispatch_log(l, 'check_reopen', 'Check reopened');
end $$;

-- Invoicing saves the customer split (supervisor), only once the checker has finished.
create or replace function public.dispatch_check_save(p_load_id bigint, p_lines jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare l loads; bad text;
begin
  perform _dispatch_require('supervisor');
  select * into l from loads where id = p_load_id for update;
  if not found then raise exception 'Load not found'; end if;
  if l.checker_done_at is null then raise exception '% hasn''t been finished by the checker yet', l.load_nbr; end if;
  if l.check_status in ('confirming', 'confirmed') then raise exception '% is already being confirmed or confirmed', l.load_nbr; end if;

  with x as (select r->>'shipment_nbr' nbr, (r->>'line_nbr')::int ln, (r->>'final_qty')::numeric q from jsonb_array_elements(p_lines) r)
  select string_agg(x.nbr || '/' || x.ln, ', ') into bad
    from x
    left join load_shipments ls on ls.load_id = p_load_id and ls.shipment_nbr = x.nbr
    left join shipment_lines sl on sl.env = l.env and sl.shipment_nbr = x.nbr and sl.line_nbr = x.ln
   where ls.shipment_nbr is null or sl.line_nbr is null or x.q < 0 or x.q > sl.shipped_qty;
  if bad is not null then raise exception 'Quantities can only be lowered, on lines of this load: %', bad; end if;

  -- Each short SKU has to add up to what the checker counted.
  select string_agg(t.inventory_id, ', ') into bad
    from (select sl.inventory_id, sum(x.q) going, max(c.checked_qty) checked
            from (select r->>'shipment_nbr' nbr, (r->>'line_nbr')::int ln, (r->>'final_qty')::numeric q from jsonb_array_elements(p_lines) r) x
            join shipment_lines sl on sl.env = l.env and sl.shipment_nbr = x.nbr and sl.line_nbr = x.ln
            join check_items c on c.load_id = p_load_id and c.inventory_id = sl.inventory_id
           group by sl.inventory_id) t
   where t.going <> t.checked;
  if bad is not null then raise exception 'Going out doesn''t match the checker''s count for: %', bad; end if;

  delete from check_lines where load_id = p_load_id;
  insert into check_lines (load_id, shipment_nbr, line_nbr, inventory_id, shipped_qty, final_qty, note)
  select p_load_id, x.nbr, x.ln, sl.inventory_id, sl.shipped_qty, x.q,
         case when x.q < sl.shipped_qty then left(nullif(trim(x.note), ''), 200) end
    from (select r->>'shipment_nbr' nbr, (r->>'line_nbr')::int ln, (r->>'final_qty')::numeric q, r->>'note' note
            from jsonb_array_elements(p_lines) r) x
    join shipment_lines sl on sl.env = l.env and sl.shipment_nbr = x.nbr and sl.line_nbr = x.ln;
  update loads set check_status = 'checking' where id = p_load_id and check_status is null;
  perform _dispatch_log(l, 'check_save', (select count(*) from check_lines where load_id = p_load_id and final_qty < shipped_qty) || ' line(s) lowered',
    (select jsonb_build_object('notes', coalesce(jsonb_agg(jsonb_build_object('shipment', shipment_nbr, 'item', inventory_id, 'note', note)), '[]'::jsonb))
       from check_lines where load_id = p_load_id and note is not null));
end $$;

-- The bundle now carries check_items too.
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
                   else '[]'::jsonb end);
end $$;

revoke all on function public.dispatch_check_item(bigint, text, numeric, boolean) from public, anon;
revoke all on function public.dispatch_check_finish(bigint) from public, anon;
revoke all on function public.dispatch_check_reopen(bigint) from public, anon;
grant execute on function public.dispatch_check_item(bigint, text, numeric, boolean) to authenticated;
grant execute on function public.dispatch_check_finish(bigint) to authenticated;
grant execute on function public.dispatch_check_reopen(bigint) to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'check_items') then
    alter publication supabase_realtime add table public.check_items;
  end if;
end $$;

-- Loads already past the old checker step (e.g. one part-confirmed) go straight to Invoicing.
update public.loads set checker_done_at = coalesce(checked_at, now()), checker_done_name = 'before the checker change'
 where check_status in ('confirming', 'partial', 'confirmed') and checker_done_at is null;

-- Rollback: put dispatch_check_save back to the 20261022230000 version and _dispatch_pickable to
-- the 20261007130000 version, then:
-- alter publication supabase_realtime drop table public.check_items;
-- drop function public.dispatch_check_item(bigint, text, numeric, boolean), public.dispatch_check_finish(bigint), public.dispatch_check_reopen(bigint);
-- drop table public.check_items;
-- alter table public.loads drop column checker_done_at, drop column checker_done_by, drop column checker_done_name;
