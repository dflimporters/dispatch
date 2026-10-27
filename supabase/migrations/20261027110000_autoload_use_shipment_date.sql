-- Auto-loads follow the shipment date.
--
-- Before: every new auto-load got today's Jamaica date, so a shipment dated tomorrow showed
-- on today's Picking list. Now load_date = greatest(shipment_date, today): a shipment dated
-- tomorrow lands in tomorrow's auto-load for its Ship Via, and anything dated today or
-- earlier (the sync still looks 2 days back) goes to today's.
--
-- Only affects shipments the sync adds from now on. Shipments already on a load stay where
-- they are, so nothing on the portal moves when this is applied. The cron job is unchanged.

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

  -- 2. Add shipments with a Ship Via and no load: one auto-load per Ship Via per load date
  --    (shipment date, never earlier than today).
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
    select * into l from loads
     where env = p_env and source = 'acumatica' and load_date = r.ld and ship_via = r.ship_via
       and status = 'done' and check_status is null
     order by id limit 1 for update;
    if not found then
      insert into loads (env, load_date, wave, seq, load_nbr, status, ship_via, source, applied_at, notes)
      values (p_env, r.ld, 'ACU', 0, '', 'done', r.ship_via, 'acumatica', now(), 'Ship Via set in Acumatica')
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
