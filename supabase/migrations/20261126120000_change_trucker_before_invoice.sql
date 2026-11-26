-- Change the trucker of a WHOLE load that is already written to Acumatica but not yet
-- checker-confirmed, i.e. while it is being picked or checked (Joel, 2026-11-26, L-2611-28).
--
-- After the checker confirms there is lm_reassign_load (invoices, DELIVERVIA). Before that the shipments
-- are still Open in Acumatica with the old ShipVia, nothing is invoiced, and the clerk's "Undo confirmation"
-- is no use because the load is already written. This puts the new ShipVia on the same shipments by re-running
-- the normal writeback (dispatch-acu apply) with the new trucker:
--
--   dispatch_change_trucker(load, ship_via, contractor, reason)   clerk only (apply is clerk-only too)
--     * load is done/partial, not being written, not checker-confirmed/confirming, no confirm queued
--     * no driver holds it (lm_loads, if any)
--     * every shipment is still On Hold/Open in Acumatica (else it must be fixed there by hand)
--     * ship_via_before := each shipment's current Ship Via (the writeback's guard), results cleared,
--       loads.ship_via := the new one, status := 'partial' (keeps it on the picker and checker lists until
--       the drain claims it), and a 'reassign' load_events row (mode 'full') so the printed banner shows it.
--   The page then calls dispatch-acu apply, exactly as for the first lock-in. Picks, checks and quantities
--   are untouched. A retry of a half-done change is the normal "Retry" on the clerk page.

create function public.dispatch_change_trucker(p_id bigint, p_ship_via text, p_contractor text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare l loads; n loads; bad text; why text := nullif(btrim(coalesce(p_reason, '')), ''); m lm_loads;
begin
  perform _dispatch_require('clerk');
  if why is null then raise exception 'Say why the trucker is changing'; end if;
  p_ship_via := nullif(btrim(coalesce(p_ship_via, '')), '');
  if p_ship_via is null or p_ship_via ilike 'BATCH%' then raise exception 'Pick the trucker''s Ship Via'; end if;
  if not exists (select 1 from ship_via_codes where ship_via = p_ship_via) then
    raise exception '% isn''t a Ship Via code in Acumatica', p_ship_via;
  end if;

  select * into l from loads where id = p_id for update;
  if not found then raise exception 'Load not found'; end if;
  if l.status not in ('done', 'partial') then
    raise exception '% is %, not written to Acumatica yet. Use Undo confirmation instead', l.load_nbr, l.status;
  end if;
  if l.write_requested_at is not null then raise exception '% is queued to be written; wait for it to finish', l.load_nbr; end if;
  if l.check_status in ('confirming', 'confirmed', 'partial') or l.confirm_requested_at is not null then
    raise exception '% is already being confirmed or confirmed by the checker. Use Change trucker on the Load Sheets page', l.load_nbr;
  end if;
  if l.ship_via is not distinct from p_ship_via then raise exception '% is already on %', l.load_nbr, p_ship_via; end if;

  select * into m from lm_loads where load_id = p_id for update;
  if found and (m.token_hash is not null or m.status <> 'ready') then
    raise exception '% has been claimed by a driver. Unassign it in Control Tower first', l.load_nbr;
  end if;

  select string_agg(ls.shipment_nbr || coalesce(' (' || s.status || ')', ' (not found)'), ', ') into bad
    from load_shipments ls
    left join _dispatch_shipments(l.env) s on s.shipment_nbr = ls.shipment_nbr
   where ls.load_id = p_id
     and (s.shipment_nbr is null or s.status not in ('On Hold', 'Open'));
  if bad is not null then
    raise exception 'These aren''t open in Acumatica any more, so fix the Ship Via there by hand: %', bad;
  end if;
  if not exists (select 1 from load_shipments where load_id = p_id) then raise exception '% has no shipments', l.load_nbr; end if;

  update load_shipments ls set ship_via_before = s.ship_via, result = null, result_detail = null, result_at = null
    from _dispatch_shipments(l.env) s
   where ls.load_id = p_id and s.shipment_nbr = ls.shipment_nbr;

  update loads set status = 'partial', ship_via = p_ship_via, contractor = nullif(btrim(p_contractor), ''),
                   applied_at = null, confirmed_by = auth.uid(), confirmed_at = now()
   where id = p_id returning * into n;

  perform _lm_reassign_log(n, 'Trucker changed from ' || coalesce(l.ship_via, '—') || ' to ' || p_ship_via || ': ' || why,
    jsonb_build_object('mode', 'full', 'phase', 'before_check', 'from_via', l.ship_via, 'to_via', p_ship_via,
                       'reason', why, 'was_contractor', l.contractor,
                       'shipments', (select coalesce(jsonb_agg(shipment_nbr order by shipment_nbr), '[]') from load_shipments where load_id = p_id)));
end $$;

revoke all on function public.dispatch_change_trucker(bigint, text, text, text) from public, anon;
grant execute on function public.dispatch_change_trucker(bigint, text, text, text) to authenticated;
