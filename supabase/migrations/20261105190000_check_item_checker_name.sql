-- "Who's checking" (Joel, 2026-11-05): the checker tablets share one login, so every tick was stamped with the
-- tablet's name. The page now asks who is checking each load and passes that name in.
--
-- dispatch_check_item gets an optional p_checker. Without it the behaviour is unchanged (the login's name), so a
-- tablet still running the old page keeps working. The old 4-argument function is dropped in the same step so
-- there is only one version for the API to pick from.

drop function if exists public.dispatch_check_item(bigint, text, numeric, boolean);

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
          checker_name = excluded.checker_name, checked_at = now();
  end if;
end $function$;

revoke all on function public.dispatch_check_item(bigint, text, numeric, boolean, text) from public, anon;
grant execute on function public.dispatch_check_item(bigint, text, numeric, boolean, text) to authenticated;
