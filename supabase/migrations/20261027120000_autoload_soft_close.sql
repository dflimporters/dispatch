-- Auto-loads are closed, never deleted, and have no AM/PM step (Joel, 2026-10-27).
--
-- Until now dispatch_autoload_sync() dropped a shipment from its auto-load as soon as Acumatica
-- completed it, then deleted the load once it was empty. L-1026-ACU-08 vanished that way: its one
-- shipment was Completed (picked outside the portal), so the load and its number were deleted, and
-- anything that had shown the number went stale.
--
-- Now:
--   * Shipments Acumatica has Completed/Invoiced/Confirmed stay on their load. Only a changed Ship
--     Via, a shipment gone from the sync, or any other status takes a shipment off.
--   * An unchecked auto-load with no Open/On Hold shipments left is CLOSED (closed_at, closed_reason),
--     not deleted. Its number, shipments and events stay. Closed loads are frozen: the sync no longer
--     takes shipments off them, so the record survives shipments aging out of the sync window.
--   * A new Open shipment for the same Ship Via and day REOPENS the day's closed load instead of
--     starting another one (one load per truck per day).
--   * The picker and checker hide closed loads (picking.html, checker.html).
--   * lm_build_invoice_load confirms the existing auto-load when it already holds exactly the ticked
--     shipments, rather than building a second load for the same truck. Otherwise it behaves as before
--     (the loads it empties are now closed, not deleted).
--   * Auto-loads stay wave 'ACU' for good, so their numbers never change. dispatch_set_wave is dropped.
--   * Includes 20261027110000_autoload_use_shipment_date (load_date = greatest(shipment_date, today));
--     this file runs after it and replaces the same function, so it must carry that change.

alter table public.loads
  add column closed_at     timestamptz,
  add column closed_reason text;
comment on column public.loads.closed_at is
  'Set when an unchecked auto-load has no Open/On Hold shipments left. Hidden from the picker and checker; the row, shipments and events are kept.';

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
  closed  int := 0;
  reopened int := 0;
begin
  if p_env not in ('live', 'test') then raise exception 'Unknown env %', p_env; end if;
  perform pg_advisory_xact_lock(hashtext('autoload:' || p_env));

  select max(synced_at) into fresh from _dispatch_shipments(p_env);
  if fresh is null or fresh < now() - interval '2 hours' then
    return jsonb_build_object('skipped', 'shipments not synced in the last 2 hours');
  end if;

  -- 1. Take off shipments Acumatica has moved elsewhere. Completed, Invoiced and Confirmed ones stay.
  --    Closed loads are frozen.
  for r in
    select l2.id, array_agg(ls.shipment_nbr order by ls.shipment_nbr) nbrs,
           jsonb_agg(jsonb_build_object('shipment', ls.shipment_nbr, 'status', s.status, 'ship_via', s.ship_via)
                     order by ls.shipment_nbr) why
      from load_shipments ls
      join loads l2 on l2.id = ls.load_id and l2.env = p_env and l2.source = 'acumatica'
                   and l2.check_status is null and l2.closed_at is null
      left join _dispatch_shipments(p_env) s on s.shipment_nbr = ls.shipment_nbr
     where ls.env = p_env
       and (s.shipment_nbr is null
            or s.status not in ('On Hold', 'Open', 'Confirmed', 'Completed', 'Invoiced')
            or s.ship_via is distinct from l2.ship_via)
     group by l2.id
  loop
    select * into l from loads where id = r.id;
    delete from load_shipments where load_id = r.id and shipment_nbr = any (r.nbrs);
    moved := moved + cardinality(r.nbrs);
    insert into load_events (load_id, env, load_nbr, kind, note, detail, actor_name)
    values (l.id, p_env, l.load_nbr, 'move', 'Acumatica changed these shipments; removed from this load',
            r.why, 'Acumatica sync');
  end loop;

  -- 1b. Close unchecked auto-loads with nothing left to pick (all Completed in Acumatica, or empty).
  for l in
    select * from loads x
     where x.env = p_env and x.source = 'acumatica' and x.check_status is null and x.closed_at is null
       and not exists (select 1 from load_shipments ls
                         join _dispatch_shipments(p_env) s on s.shipment_nbr = ls.shipment_nbr
                        where ls.load_id = x.id and s.status in ('On Hold', 'Open'))
  loop
    update loads
       set closed_at = now(),
           closed_reason = case when exists (select 1 from load_shipments where load_id = l.id)
                                then 'Completed in Acumatica' else 'Empty after Acumatica changes' end
     where id = l.id
     returning * into l;
    insert into load_events (load_id, env, load_nbr, kind, note, ship_via, actor_name)
    values (l.id, p_env, l.load_nbr, 'close', l.closed_reason, l.ship_via, 'Acumatica sync');
    closed := closed + 1;
  end loop;

  -- 2. Add shipments with a Ship Via and no load.
  for r in
    select s.ship_via, greatest(s.shipment_date, d) ld, array_agg(s.shipment_nbr order by s.shipment_nbr) nbrs
      from _dispatch_shipments(p_env) s
      join ship_via_codes c on c.ship_via = s.ship_via
     where s.operation = 'Issue' and coalesce(s.order_type, '') <> 'RC'
       and s.status in ('On Hold', 'Open')
       and s.ship_via not ilike 'BATCH%'
       and s.shipment_date >= d - 2
       and not exists (select 1 from load_shipments x where x.env = p_env and x.shipment_nbr = s.shipment_nbr)
       and exists (select 1 from shipment_lines sl
                    where sl.env = p_env and sl.shipment_nbr = s.shipment_nbr and sl.shipped_qty > 0)
     group by s.ship_via, greatest(s.shipment_date, d)
  loop
    -- The load date's load for this Ship Via: an open one if there is, else reopen the closed one.
    select * into l from loads
     where env = p_env and source = 'acumatica' and load_date = r.ld and ship_via = r.ship_via
       and status = 'done' and check_status is null
     order by (closed_at is null) desc, id limit 1 for update;
    if not found then
      insert into loads (env, load_date, wave, seq, load_nbr, status, ship_via, source, applied_at, notes)
      values (p_env, r.ld, 'ACU', 0, '', 'done', r.ship_via, 'acumatica', now(), 'Ship Via set in Acumatica')
      returning * into l;
      made := made + 1;
      insert into load_events (load_id, env, load_nbr, kind, note, ship_via, detail, actor_name)
      values (l.id, p_env, l.load_nbr, 'create', 'Created from a Ship Via set in Acumatica', r.ship_via,
              jsonb_build_object('shipments', r.nbrs), 'Acumatica sync');
    elsif l.closed_at is not null then
      update loads set closed_at = null, closed_reason = null where id = l.id;
      reopened := reopened + 1;
      insert into load_events (load_id, env, load_nbr, kind, note, ship_via, detail, actor_name)
      values (l.id, p_env, l.load_nbr, 'reopen', 'Reopened: new shipments with this Ship Via', r.ship_via,
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

  return jsonb_build_object('loads_created', made, 'loads_reopened', reopened, 'shipments_added', added,
                            'shipments_removed', moved, 'loads_closed', closed);
end $$;

-- No AM/PM step: an auto-load keeps its ACU number.
drop function public.dispatch_set_wave(bigint, text);

-- Build (or confirm) the load for shipments picked and invoiced outside the portal.
-- Unchanged except: (a) when one unchecked auto-load already holds exactly the ticked shipments, that
-- load is confirmed instead of building a second one; (b) the takeover path leaves the emptied
-- auto-load for the sync to close.
create or replace function public.lm_build_invoice_load(p_ship_via text, p_shipments text[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  d    date := (now() at time zone 'America/Jamaica')::date;
  n    text;
  s    shipments;
  ex   record;
  l    loads;
  ids  bigint[];
  who  text := dispatch_actor_name();
  code text;
begin
  if auth.uid() is null or not lm_staff() then
    raise exception 'Your account doesn''t have a dispatch role' using errcode = '42501';
  end if;
  if p_ship_via is null or not exists (select 1 from ship_via_codes where ship_via = p_ship_via) then
    raise exception 'Unknown Ship Via';
  end if;
  if coalesce(cardinality(p_shipments), 0) = 0 then raise exception 'Tick at least one shipment'; end if;
  perform pg_advisory_xact_lock(hashtext('lm_invoice_load'));

  foreach n in array p_shipments loop
    select * into s from shipments where shipment_nbr = n;
    if not found then raise exception 'Shipment % not found', n; end if;
    if s.ship_via is distinct from p_ship_via then raise exception 'Shipment % is on %, not %', n, s.ship_via, p_ship_via; end if;
    if s.status <> 'Completed' then raise exception 'Shipment % is % in Acumatica, not Completed', n, s.status; end if;
    if not exists (select 1 from shipment_lines where env = 'live' and shipment_nbr = n and shipped_qty > 0) then
      raise exception 'Shipment % has no item lines synced from Acumatica yet', n;
    end if;
    select l2.load_nbr, (l2.source = 'acumatica' and l2.check_status is null) as reusable into ex
      from load_shipments ls join loads l2 on l2.id = ls.load_id
     where ls.env = 'live' and ls.shipment_nbr = n limit 1;
    if found and not ex.reusable then raise exception 'Shipment % is already on %', n, ex.load_nbr; end if;
  end loop;

  -- One unchecked auto-load for this Ship Via holds exactly the ticked shipments: confirm it.
  select array_agg(distinct ls.load_id) into ids
    from load_shipments ls join loads l2 on l2.id = ls.load_id
   where ls.env = 'live' and ls.shipment_nbr = any (p_shipments)
     and l2.source = 'acumatica' and l2.check_status is null;
  if cardinality(ids) = 1 then
    select * into l from loads where id = ids[1] for update;
    if l.ship_via = p_ship_via
       and (select count(*) from load_shipments where load_id = l.id) = cardinality(p_shipments)
       and (select count(*) from load_shipments where load_id = l.id and shipment_nbr = any (p_shipments))
         = cardinality(p_shipments) then
      update loads
         set check_status = 'confirmed', checked_by = auth.uid(), checked_at = now(),
             closed_at = null, closed_reason = null,
             notes = coalesce(nullif(notes, '') || '. ', '') || 'Picked outside the portal'
       where id = l.id
       returning * into l;
      update load_shipments
         set check_result = 'applied', check_detail = 'Picked outside the portal', check_at = now()
       where load_id = l.id;
      insert into load_events (load_id, env, load_nbr, kind, note, ship_via, detail, actor_name)
      values (l.id, 'live', l.load_nbr, 'confirm', 'Confirmed from invoices (picked outside the portal)', p_ship_via,
              jsonb_build_object('shipments', p_shipments), who);
      code := lm_ensure_load(l.id);
      return jsonb_build_object('load_id', l.id, 'load_nbr', l.load_nbr, 'code', code,
                                'shipments', cardinality(p_shipments), 'reused', true);
    end if;
  end if;

  -- Otherwise: take the ticked shipments off their auto-load (the sync closes it if that empties it)
  -- and build a new load.
  delete from load_shipments
   where env = 'live' and shipment_nbr = any (p_shipments)
     and load_id in (select id from loads where source = 'acumatica' and check_status is null);

  insert into loads (env, load_date, wave, seq, load_nbr, status, ship_via, source, applied_at,
                     check_status, checked_by, checked_at, notes, created_by)
  values ('live', d, 'ACU', 0, '', 'done', p_ship_via, 'invoice', now(),
          'confirmed', auth.uid(), now(), 'Built from invoices: picked outside the portal', auth.uid())
  returning * into l;

  insert into load_shipments (env, shipment_nbr, load_id, added_by, result, result_detail, result_at,
                              check_result, check_detail, check_at)
  select 'live', x, l.id, auth.uid(), 'applied', 'Picked outside the portal', now(),
         'applied', 'Picked outside the portal', now()
    from unnest(p_shipments) x;

  insert into load_events (load_id, env, load_nbr, kind, note, ship_via, detail, actor_name)
  values (l.id, 'live', l.load_nbr, 'create', 'Built from invoices (picked outside the portal)', p_ship_via,
          jsonb_build_object('shipments', p_shipments), who);

  code := lm_ensure_load(l.id);
  return jsonb_build_object('load_id', l.id, 'load_nbr', l.load_nbr, 'code', code, 'shipments', cardinality(p_shipments));
end $$;
