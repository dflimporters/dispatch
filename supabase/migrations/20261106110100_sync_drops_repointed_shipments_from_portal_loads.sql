-- A shipment whose Ship Via is changed in Acumatica after it was written to a portal-built load
-- (e.g. DWRIGHTTRK01 -> PICKUPTRK01) stayed on the old load for good, because the Acumatica sync only
-- cleaned up auto-loads (Joel, 2026-11-06: 283716 on L-0611-04).
--
-- Adds step 1a to dispatch_autoload_sync: on a portal-built (source 'clerk') load that is written
-- (done/partial), not yet confirmed by the invoicer (check_status null) and not closed, a shipment that
-- was applied and now has a different Ship Via in Acumatica comes off the load, with a history entry.
-- Refused/failed shipments are left for the batcher to re-home. Patches the live function text
-- so nothing else in it changes.

do $do$
declare
  def text := pg_get_functiondef('public.dispatch_autoload_sync(text)'::regprocedure);
  marker text := '  -- 1b. Close unchecked';
  blk text := $blk$
  -- 1a. Portal-built loads: a written shipment whose Ship Via was changed in Acumatica comes off.
  for r in
    select l2.id, array_agg(ls.shipment_nbr order by ls.shipment_nbr) nbrs,
           jsonb_agg(jsonb_build_object('shipment', ls.shipment_nbr, 'status', s.status, 'ship_via', s.ship_via)
                     order by ls.shipment_nbr) why
      from load_shipments ls
      join loads l2 on l2.id = ls.load_id and l2.env = p_env and l2.source = 'clerk'
                   and l2.status in ('done', 'partial') and l2.check_status is null and l2.closed_at is null
                   and l2.ship_via is not null
      join _dispatch_shipments(p_env) s on s.shipment_nbr = ls.shipment_nbr
     where ls.env = p_env and ls.result = 'applied' and s.ship_via is distinct from l2.ship_via
     group by l2.id
  loop
    select * into l from loads where id = r.id;
    delete from load_shipments where load_id = r.id and shipment_nbr = any (r.nbrs);
    moved := moved + cardinality(r.nbrs);
    insert into load_events (load_id, env, load_nbr, kind, note, detail, actor_name)
    values (l.id, p_env, l.load_nbr, 'move', 'Ship Via changed in Acumatica; removed from this load',
            r.why, 'Acumatica sync');
  end loop;

$blk$;
  new text;
begin
  new := replace(def, marker, blk || marker);
  if new = def then raise exception 'step 1b marker not found in dispatch_autoload_sync'; end if;
  execute new;
end $do$;
