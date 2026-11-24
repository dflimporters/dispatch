-- 2026-11-23 (Joel). "Cancel shipment" from the portal. Acumatica can't cancel a shipment, only delete it, and the team
-- deletes them. The dispatch-acu action cancel_shipment (supervisor / admin only) now does the delete from here, so
-- the goods list, the reason and the warning to the warehouse come with it (see 20261123140000_shipment_gone_guard.sql).
--
-- Order of work in the edge function: _cancel_shipment_check (read-only, refuses if the load is mid-confirm or the
-- shipment isn't on a load) -> Acumatica status check -> Acumatica DELETE -> _cancel_shipment_done. Nothing here is
-- written until Acumatica has deleted it, so a refusal by Acumatica leaves everything as it was. If _done failed after
-- the delete, the minute job (_flag_gone_shipments) finds the shipment missing and records it anyway.
--
-- _gone_record is the snapshot / cap / log step that _flag_gone_shipments used inline; both now share it.
-- Service role only. Rollback at the bottom.

create or replace function public._gone_record(p_load_id bigint, p_nbr text, p_cause text, p_reason text default null, p_actor text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l loads; v_lines jsonb; v_ord text; v_cust text; v_touched boolean;
begin
  select * into l from loads where id = p_load_id for update;
  if not found then raise exception 'Load not found'; end if;
  select max(order_nbr) into v_ord from shipment_lines where env = l.env and shipment_nbr = p_nbr;
  select customer_name into v_cust from sales_orders where order_nbr = v_ord limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('inventory_id', x.inventory_id, 'description', x.description, 'uom', x.uom,
                                               'qty', x.qty, 'picked', pl.picked_qty, 'counted', ci.checked_qty) order by x.inventory_id), '[]'::jsonb)
    into v_lines
    from (select inventory_id, max(description) description, max(uom) uom, sum(shipped_qty) qty
            from shipment_lines where env = l.env and shipment_nbr = p_nbr and shipped_qty > 0 group by inventory_id) x
    left join pick_lines  pl on pl.load_id = l.id and pl.inventory_id = x.inventory_id
    left join check_items ci on ci.load_id = l.id and ci.inventory_id = x.inventory_id;
  v_touched := exists (select 1 from jsonb_array_elements(v_lines) e where e->>'picked' is not null or e->>'counted' is not null);

  insert into load_gone_shipments (env, load_id, shipment_nbr, order_nbr, customer_name, lines, touched)
  values (l.env, l.id, p_nbr, v_ord, v_cust, v_lines, v_touched)
  on conflict (load_id, shipment_nbr) do nothing;

  update check_items c set checked_qty = least(c.checked_qty, _load_remaining(c.load_id, c.inventory_id))
   where c.load_id = l.id and c.inventory_id in (select e->>'inventory_id' from jsonb_array_elements(v_lines) e)
     and c.checked_qty > _load_remaining(c.load_id, c.inventory_id);
  update pick_lines p set picked_qty = least(p.picked_qty, _load_remaining(p.load_id, p.inventory_id))
   where p.load_id = l.id and p.inventory_id in (select e->>'inventory_id' from jsonb_array_elements(v_lines) e)
     and p.picked_qty > _load_remaining(p.load_id, p.inventory_id);
  update loads set sheet_stale_at = now() where id = l.id;

  if p_cause = 'cancelled' then
    perform _dispatch_log(l, 'shipment_cancel',
      'Shipment ' || p_nbr || coalesce(' (SO ' || v_ord || coalesce(', ' || v_cust, '') || ')', '') || ' cancelled by ' || coalesce(p_actor, '?')
        || ': ' || coalesce(p_reason, 'no reason given') || case when v_touched then ' (already picked/checked: goods to come off the truck)' else '' end,
      jsonb_build_object('shipment', p_nbr, 'order', v_ord, 'touched', v_touched, 'reason', p_reason, 'lines', v_lines));
  else
    perform _dispatch_log(l, 'shipment_gone',
      'Shipment ' || p_nbr || coalesce(' (SO ' || v_ord || coalesce(', ' || v_cust, '') || ')', '')
        || ' was deleted in Acumatica' || case when v_touched then ' after picking/checking started: goods may need to come off the truck' else '' end,
      jsonb_build_object('shipment', p_nbr, 'order', v_ord, 'touched', v_touched, 'lines', v_lines));
  end if;
  return jsonb_build_object('touched', v_touched, 'order_nbr', v_ord, 'customer_name', v_cust, 'load_nbr', l.load_nbr, 'lines', v_lines);
end $$;
revoke all on function public._gone_record(bigint, text, text, text, text) from public, anon, authenticated;
grant execute on function public._gone_record(bigint, text, text, text, text) to service_role;

-- The minute job, now calling _gone_record (behaviour as before).
create or replace function public._flag_gone_shipments() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_fresh timestamptz;
begin
  select max(synced_at) into v_fresh from shipments;
  if v_fresh is null or v_fresh < now() - interval '30 minutes' then return 0; end if;

  delete from gone_pending p where exists (select 1 from shipments s where s.shipment_nbr = p.shipment_nbr)
                                or not exists (select 1 from load_shipments ls where ls.env = p.env and ls.shipment_nbr = p.shipment_nbr);
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
    perform _gone_record(r.load_id, r.shipment_nbr, 'deleted');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public._flag_gone_shipments() from public, anon, authenticated;

-- Read-only: is this shipment cancellable from the portal? Returns the load it is on.
create or replace function public._cancel_shipment_check(p_env text, p_nbr text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l loads;
begin
  select l2.* into l from load_shipments ls join loads l2 on l2.id = ls.load_id where ls.env = p_env and ls.shipment_nbr = p_nbr;
  if not found then raise exception 'Shipment % isn''t on a load here', p_nbr; end if;
  if l.check_status = 'confirming' or l.confirm_requested_at is not null then
    raise exception '% is being confirmed in Acumatica right now. Wait for it to finish.', l.load_nbr; end if;
  if l.check_status = 'confirmed' then
    raise exception '% is already confirmed in Acumatica; a confirmed shipment can''t be deleted (it needs a return).', l.load_nbr; end if;
  if exists (select 1 from load_gone_shipments g where g.load_id = l.id and g.shipment_nbr = p_nbr) then
    raise exception 'Shipment % is already flagged as deleted on %', p_nbr, l.load_nbr; end if;
  return jsonb_build_object('load_id', l.id, 'load_nbr', l.load_nbr, 'check_status', l.check_status);
end $$;
revoke all on function public._cancel_shipment_check(text, text) from public, anon, authenticated;
grant execute on function public._cancel_shipment_check(text, text) to service_role;

-- After Acumatica has deleted it. Records what was on it, caps the picker's and checker's numbers, drops it from the
-- mirror, and, if nothing had been picked or counted for it, takes it off the load at once (otherwise it stays flagged
-- until a supervisor says what happened to the goods).
create or replace function public._cancel_shipment_done(p_env text, p_nbr text, p_reason text, p_actor text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c jsonb; r jsonb;
begin
  c := _cancel_shipment_check(p_env, p_nbr);
  r := _gone_record((c->>'load_id')::bigint, p_nbr, 'cancelled', p_reason, p_actor);
  if p_env = 'live' then delete from shipments where shipment_nbr = p_nbr;
  else delete from shipments_test where shipment_nbr = p_nbr; end if;
  if not (r->>'touched')::boolean then
    update load_gone_shipments set ack_at = now(), ack_name = p_actor, ack_note = 'Cancelled before anything was picked: nothing to return'
     where load_id = (c->>'load_id')::bigint and shipment_nbr = p_nbr and ack_at is null;
    delete from load_shipments where load_id = (c->>'load_id')::bigint and shipment_nbr = p_nbr;
  end if;
  return r || jsonb_build_object('load_id', (c->>'load_id')::bigint);
end $$;
revoke all on function public._cancel_shipment_done(text, text, text, text) from public, anon, authenticated;
grant execute on function public._cancel_shipment_done(text, text, text, text) to service_role;

-- Rollback (by hand): restore _flag_gone_shipments from 20261123140000_shipment_gone_guard.sql (the apply_migration
-- copy of it has the same body); drop function public._cancel_shipment_done(text, text, text, text),
-- public._cancel_shipment_check(text, text), public._gone_record(bigint, text, text, text, text).
