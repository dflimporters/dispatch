-- Loads for shipments whose Ship Via was set directly in Acumatica (Joel, 2026-10-22).
--
-- The picker and checker list loads, and a load only existed when the batcher built it and
-- the clerk locked in a trucker. A shipment given a Ship Via in Acumatica was on no load, so
-- nobody could pick or check it.
--
-- dispatch_autoload_sync() fixes that. Every few minutes it
--   1. DROPS shipments from auto-loads that nobody has started checking when Acumatica has
--      moved on: Ship Via changed, no longer Open/On Hold, or gone from the sync. Empty
--      auto-loads with no picks are deleted. A shipment whose Ship Via changed is re-homed
--      by step 2 on the same run.
--   2. ADDS every Open/On Hold outbound shipment that has a real Ship Via, item lines, a
--      shipment date within the last 2 days (or later) and no load, to one auto-load per
--      Ship Via per day. DWRIGHT and DWRIGHT2 are different codes, so they get separate loads.
--
-- An auto-load is source 'acumatica', status 'done' (the Ship Via is already in Acumatica,
-- so there is nothing to write back), wave 'ACU' (unsorted) and load_date = the Jamaica date
-- the sync first saw it. Whoever sees it first sets AM or PM with dispatch_set_wave.
-- The checker's Confirm works as for any load.
--
-- It skips the run if the shipments table hasn't synced in 2 hours, so a sync outage can't
-- empty loads.

alter table public.loads
  add column source text not null default 'clerk' check (source in ('clerk', 'acumatica'));

alter table public.loads drop constraint loads_wave_check;
alter table public.loads add constraint loads_wave_check check (wave in ('AM', 'PM', 'ACU'));

-- Which trucker a Ship Via code belongs to (DWRIGHT2 -> DWRIGHT). Filled from a sheet.
-- Nothing reads it yet; trucker pay and the dashboard will group on it.
alter table public.ship_via_codes add column if not exists base_trucker text;
comment on column public.ship_via_codes.base_trucker is
  'The trucker this code belongs to, so DWRIGHT and DWRIGHT2 are one trucker. Null = the code is its own trucker.';

create or replace function public.dispatch_autoload_sync(p_env text default 'live') returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  d       date := (now() at time zone 'America/Jamaica')::date;
  fresh   timestamptz;
  r       record;
  l       loads;
  moved   int := 0;
  added   int := 0;
  made    int := 0;
  gone    int := 0;
begin
  if p_env not in ('live', 'test') then raise exception 'Unknown env %', p_env; end if;
  perform pg_advisory_xact_lock(hashtext('autoload:' || p_env));

  select max(synced_at) into fresh from _dispatch_shipments(p_env);
  if fresh is null or fresh < now() - interval '2 hours' then
    return jsonb_build_object('skipped', 'shipments not synced in the last 2 hours');
  end if;

  -- 1. Drop what Acumatica has moved away from.
  for r in
    select l2.id, array_agg(ls.shipment_nbr order by ls.shipment_nbr) nbrs,
           jsonb_agg(jsonb_build_object('shipment', ls.shipment_nbr, 'status', s.status, 'ship_via', s.ship_via)
                     order by ls.shipment_nbr) why
      from load_shipments ls
      join loads l2 on l2.id = ls.load_id and l2.env = p_env and l2.source = 'acumatica' and l2.check_status is null
      left join _dispatch_shipments(p_env) s on s.shipment_nbr = ls.shipment_nbr
     where ls.env = p_env
       and (s.shipment_nbr is null or s.status not in ('On Hold', 'Open') or s.ship_via is distinct from l2.ship_via)
     group by l2.id
  loop
    select * into l from loads where id = r.id;
    delete from load_shipments where load_id = r.id and shipment_nbr = any (r.nbrs);
    moved := moved + cardinality(r.nbrs);
    insert into load_events (load_id, env, load_nbr, kind, note, detail, actor_name)
    values (l.id, p_env, l.load_nbr, 'move', 'Acumatica changed these shipments; removed from this load',
            r.why, 'Acumatica sync');
  end loop;

  for l in
    select * from loads x
     where x.env = p_env and x.source = 'acumatica' and x.check_status is null
       and not exists (select 1 from load_shipments where load_id = x.id)
       and not exists (select 1 from pick_lines where load_id = x.id)
  loop
    insert into load_events (load_id, env, load_nbr, kind, note, ship_via, actor_name)
    values (l.id, p_env, l.load_nbr, 'delete', 'Empty after Acumatica changes', l.ship_via, 'Acumatica sync');
    delete from loads where id = l.id;
    gone := gone + 1;
  end loop;

  -- 2. Add shipments with a Ship Via and no load.
  for r in
    select s.ship_via, array_agg(s.shipment_nbr order by s.shipment_nbr) nbrs
      from _dispatch_shipments(p_env) s
      join ship_via_codes c on c.ship_via = s.ship_via
     where s.operation = 'Issue' and coalesce(s.order_type, '') <> 'RC'
       and s.status in ('On Hold', 'Open')
       and s.ship_via not ilike 'BATCH%'
       and s.shipment_date >= d - 2
       and not exists (select 1 from load_shipments x where x.env = p_env and x.shipment_nbr = s.shipment_nbr)
       and exists (select 1 from shipment_lines sl
                    where sl.env = p_env and sl.shipment_nbr = s.shipment_nbr and sl.shipped_qty > 0)
     group by s.ship_via
  loop
    select * into l from loads
     where env = p_env and source = 'acumatica' and load_date = d and ship_via = r.ship_via
       and status = 'done' and check_status is null
     order by id limit 1 for update;
    if not found then
      insert into loads (env, load_date, wave, seq, load_nbr, status, ship_via, source, applied_at, notes)
      values (p_env, d, 'ACU', 0, '', 'done', r.ship_via, 'acumatica', now(), 'Ship Via set in Acumatica')
      returning * into l;
      made := made + 1;
      insert into load_events (load_id, env, load_nbr, kind, note, ship_via, detail, actor_name)
      values (l.id, p_env, l.load_nbr, 'create', 'Created from a Ship Via set in Acumatica', r.ship_via,
              jsonb_build_object('shipments', r.nbrs), 'Acumatica sync');
    else
      insert into load_events (load_id, env, load_nbr, kind, note, ship_via, detail, actor_name)
      values (l.id, p_env, l.load_nbr, 'move', 'Added: Ship Via set in Acumatica', r.ship_via,
              jsonb_build_object('shipments', r.nbrs), 'Acumatica sync');
    end if;
    insert into load_shipments (env, shipment_nbr, load_id, added_by, result, result_detail, result_at)
    select p_env, n, l.id, null, 'applied', 'Ship Via set in Acumatica', now() from unnest(r.nbrs) n;
    added := added + cardinality(r.nbrs);
  end loop;

  return jsonb_build_object('loads_created', made, 'shipments_added', added,
                            'shipments_removed', moved, 'loads_deleted', gone);
end $$;

revoke all on function public.dispatch_autoload_sync(text) from public, anon, authenticated;

-- Set AM or PM on an auto-load (renumbers it into that wave's sequence). Any dispatch role.
-- Only auto-loads, and only until the checker starts confirming: clerk loads' numbers are
-- already in Acumatica, an auto-load's never is.
create or replace function public.dispatch_set_wave(p_id bigint, p_wave text) returns void
language plpgsql security definer set search_path = public as $$
declare l loads; n loads;
begin
  if auth.uid() is null or not dispatch_has_role() then
    raise exception 'Sign in first' using errcode = '42501';
  end if;
  if p_wave not in ('AM', 'PM') then raise exception 'Wave must be AM or PM'; end if;
  select * into l from loads where id = p_id for update;
  if not found then raise exception 'Load not found'; end if;
  if l.source <> 'acumatica' then raise exception '% was built in Dispatch; its wave can''t change here', l.load_nbr; end if;
  if l.check_status in ('confirming', 'confirmed') then raise exception '% has already been confirmed', l.load_nbr; end if;
  if l.wave = p_wave then return; end if;
  update loads set wave = p_wave where id = p_id returning * into n;
  perform _dispatch_log(n, 'edit', 'Wave set to ' || p_wave,
    jsonb_build_object('wave', jsonb_build_array(l.wave, n.wave), 'old_nbr', l.load_nbr));
end $$;

revoke all on function public.dispatch_set_wave(bigint, text) from public, anon;
grant execute on function public.dispatch_set_wave(bigint, text) to authenticated;

-- Run it every 2 minutes for production. (The sync that fills shipments runs elsewhere.)
select cron.schedule('dispatch-autoload-2min', '*/2 * * * *', $cron$ select public.dispatch_autoload_sync('live') $cron$);
