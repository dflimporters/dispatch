-- 2026-11-05. Substitution flag (Joel): a checker who can't find an item records the count (0 or short) and flags the
-- line "substitution needed", with a free-text note. Invoicing sees the flag in a worklist, sorts the substitution in
-- Acumatica by hand (new SO, release, add to the shipment, zero the unfound line), then marks it resolved here.
-- Nothing is written to Acumatica from the portal. Printing an invoice on a load with an unresolved flag warns;
-- the clerk can override, and the override is logged on the load.
--
-- The flag lives on check_items (one row per load + SKU, like the count), so it follows the count:
--   * only a short line (checked < what the load needs) can be flagged;
--   * raising the count back to the full amount clears the flag (done inside dispatch_check_item);
--   * clearing the count deletes the row and the flag with it.
--
-- Checkers only can flag. Resolving / overriding is the supervisor (invoicing) role.
-- Rollback at the bottom.

alter table public.check_items
  add column sub_needed        boolean not null default false,
  add column sub_note          text,
  add column sub_by_name       text,
  add column sub_at            timestamptz,
  add column sub_resolved_at   timestamptz,
  add column sub_resolved_name text,
  add column sub_resolution    text;

create index check_items_sub_open_idx on public.check_items (load_id) where sub_needed and sub_resolved_at is null;

-- The count changed: same as before, plus the flag is dropped when the line is no longer short.
create or replace function public.dispatch_check_item(p_load_id bigint, p_inventory_id text, p_qty numeric, p_confirmed boolean, p_checker text default null)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare l loads; req numeric; who text := nullif(left(btrim(coalesce(p_checker, '')), 60), '');
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
    values (p_load_id, p_inventory_id, p_qty, p_confirmed, coalesce(who, dispatch_actor_name()))
    on conflict (load_id, inventory_id) do update
      set checked_qty = excluded.checked_qty, confirmed = excluded.confirmed, checked_by = auth.uid(),
          checker_name = excluded.checker_name, checked_at = now(),
          sub_needed = case when excluded.checked_qty >= req then false else check_items.sub_needed end,
          sub_note   = case when excluded.checked_qty >= req then null  else check_items.sub_note end,
          sub_by_name = case when excluded.checked_qty >= req then null else check_items.sub_by_name end,
          sub_at     = case when excluded.checked_qty >= req then null  else check_items.sub_at end,
          sub_resolved_at   = case when excluded.checked_qty >= req then null else check_items.sub_resolved_at end,
          sub_resolved_name = case when excluded.checked_qty >= req then null else check_items.sub_resolved_name end,
          sub_resolution    = case when excluded.checked_qty >= req then null else check_items.sub_resolution end;
  end if;
end $function$;

-- Checker: flag / unflag a line, with a note. The count must already be saved and short.
create function public.dispatch_check_sub(p_load_id bigint, p_inventory_id text, p_needed boolean, p_note text default null, p_checker text default null)
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
           sub_resolved_at = null, sub_resolved_name = null, sub_resolution = null
     where load_id = p_load_id and inventory_id = p_inventory_id;
    perform _dispatch_log(l, 'sub_flag', item_desc || ' (' || p_inventory_id || '): short ' || (req - c.checked_qty) || coalesce(' · ' || nt, ''));
  else
    update check_items set sub_needed = false, sub_note = null, sub_by_name = null, sub_at = null,
           sub_resolved_at = null, sub_resolved_name = null, sub_resolution = null
     where load_id = p_load_id and inventory_id = p_inventory_id and sub_needed;
    if found then perform _dispatch_log(l, 'sub_unflag', item_desc || ' (' || p_inventory_id || ')'); end if;
  end if;
end $$;

-- Invoicing: mark a flagged line sorted (or put it back to open). Works whether or not the load is confirmed yet.
create function public.dispatch_sub_resolve(p_load_id bigint, p_inventory_id text, p_resolved boolean, p_resolution text default null)
returns void language plpgsql security definer set search_path = public as $$
declare l loads; c check_items; rs text := left(nullif(btrim(coalesce(p_resolution, '')), ''), 200);
begin
  perform _dispatch_require('supervisor');
  select * into l from loads where id = p_load_id for update;
  if not found then raise exception 'Load not found'; end if;
  select * into c from check_items where load_id = p_load_id and inventory_id = p_inventory_id and sub_needed for update;
  if not found then raise exception 'That line isn''t flagged for a substitution'; end if;
  if p_resolved then
    update check_items set sub_resolved_at = now(), sub_resolved_name = dispatch_actor_name(), sub_resolution = rs
     where load_id = p_load_id and inventory_id = p_inventory_id;
    perform _dispatch_log(l, 'sub_resolve', p_inventory_id || coalesce(' · ' || rs, ''));
  else
    update check_items set sub_resolved_at = null, sub_resolved_name = null, sub_resolution = null
     where load_id = p_load_id and inventory_id = p_inventory_id;
    perform _dispatch_log(l, 'sub_reopen', p_inventory_id);
  end if;
end $$;

-- Invoicing: the clerk printed invoices on a load that still had open substitutions. Logged so there is a trail.
create function public.dispatch_sub_override(p_load_id bigint, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare l loads; n int;
begin
  perform _dispatch_require('supervisor');
  select * into l from loads where id = p_load_id;
  if not found then raise exception 'Load not found'; end if;
  select count(*) into n from check_items where load_id = p_load_id and sub_needed and sub_resolved_at is null;
  if n > 0 then
    perform _dispatch_log(l, 'sub_override', 'Printed with ' || n || ' open substitution(s)' || coalesce(' · ' || left(nullif(btrim(p_note), ''), 200), ''));
  end if;
end $$;

revoke all on function public.dispatch_check_sub(bigint, text, boolean, text, text) from public, anon;
revoke all on function public.dispatch_sub_resolve(bigint, text, boolean, text) from public, anon;
revoke all on function public.dispatch_sub_override(bigint, text) from public, anon;
grant execute on function public.dispatch_check_sub(bigint, text, boolean, text, text) to authenticated;
grant execute on function public.dispatch_sub_resolve(bigint, text, boolean, text) to authenticated;
grant execute on function public.dispatch_sub_override(bigint, text) to authenticated;

-- Rollback: put dispatch_check_item back to the 20261105190000 version, then:
-- drop function public.dispatch_check_sub(bigint, text, boolean, text, text), public.dispatch_sub_resolve(bigint, text, boolean, text), public.dispatch_sub_override(bigint, text);
-- drop index public.check_items_sub_open_idx;
-- alter table public.check_items drop column sub_needed, drop column sub_note, drop column sub_by_name, drop column sub_at,
--   drop column sub_resolved_at, drop column sub_resolved_name, drop column sub_resolution;
