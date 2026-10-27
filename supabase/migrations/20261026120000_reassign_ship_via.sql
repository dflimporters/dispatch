-- Change the trucker (Ship Via) of a load AFTER it has been invoiced (Joel, 2026-10-26).
--
-- Two cases, both only while no driver has claimed the load:
--   lm_reassign_load(load, ship_via, reason)
--       Full: the whole load goes to another trucker. loads.ship_via changes; the load number,
--       claim code and stops stay, so the printed QR keeps working but the sheet must be reprinted
--       to show the new trucker.
--   lm_reassign_shipments(shipments[], ship_via, reason, target_load)
--       Partial: some shipments (their invoices) leave their load for another trucker's load.
--       target_load null = join today's matching unclaimed load of that Ship Via if there is one,
--       else create a new load (source 'reassign', numbered by the normal L-MMDD-WAVE-NN rule).
--       p_invoices (optional) = exactly which invoices move; default = the order's invoices on the load's
--       current Ship Via dated on/after the load date (older invoices of the order stay).
--       A load can't be emptied this way (use the full change); checker results (check_lines) follow
--       the shipment, so the sheet and the driver checklist read the right quantities.
--
-- Who: clerk (Trucker Liaison), supervisor, manager. Reason is mandatory.
-- Guard: the source and target loads must be checker-confirmed and unclaimed (no lm_loads row, or
-- status 'ready' with nobody holding it). Rows are locked (loads, then lm_loads, in id order), and
-- lm_claim locks the same lm_loads row, so a driver can't scan in the middle of a change.
-- Once a driver has the load, the office unassigns it first (lm_unassign) and then reassigns.
--
-- Audit: load_events kind 'reassign' on every load touched (who, when, why, from/to, shipments,
-- invoices) and lm_events 'reassign' (office) on loads that have a claim code. Both append-only
-- in effect (load_events is only written by functions).
--
-- Acumatica: the shipment is already Confirmed/invoiced, so its ShipVia and LOADNBR stay as
-- written. The portal's loads.ship_via is the effective trucker (pay reads it). Per the 10-22
-- design the invoice gets the UDF DELIVERVIA = the trucker's Ship Via. invoice_deliver_via holds
-- one row per affected invoice and its writeback state; dispatch-acu action deliverv_write
-- sends the pending ones (off until DISPATCH_LIVE_DELIVERVIA = 'on' and the UDF exists).
-- Which invoices belong to a shipment: those of its order whose effective Ship Via is the load's
-- current one (the same order-number link lm_invoice_search uses).

alter table public.loads drop constraint loads_source_check;
alter table public.loads add constraint loads_source_check check (source in ('clerk', 'acumatica', 'invoice', 'reassign'));

alter table public.loads add column sheet_stale_at timestamptz;   -- set when a printed sheet is out of date; lm_sheet clears it

create table public.invoice_deliver_via (
  invoice_nbr   text primary key,
  env           text not null,
  shipment_nbr  text,
  load_id       bigint references public.loads(id) on delete set null,
  load_nbr      text,
  original_via  text,            -- invoices.ship_via when first reassigned
  deliver_via   text not null,   -- the trucker who actually delivers
  reason        text,
  set_by        uuid default auth.uid(),
  set_by_name   text,
  set_at        timestamptz not null default now(),
  --   pending  not yet written to Acumatica     written  UDF set     failed  see acu_detail
  --   skipped  not needed (test env, or invoice already Closed)
  acu_state     text not null default 'pending' check (acu_state in ('pending', 'written', 'failed', 'skipped')),
  acu_detail    text,
  acu_at        timestamptz
);
create index invoice_deliver_via_pending on public.invoice_deliver_via (acu_state) where acu_state in ('pending', 'failed');
create index invoice_deliver_via_load on public.invoice_deliver_via (load_id);
alter table public.invoice_deliver_via enable row level security;
create policy invoice_deliver_via_read on public.invoice_deliver_via for select to authenticated using (public.dispatch_has_role());
revoke all on public.invoice_deliver_via from anon;
revoke insert, update, delete, truncate on public.invoice_deliver_via from authenticated;

-- ------------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------------
create function public._lm_can_reassign() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from dispatch_roles where user_id = auth.uid() and role in ('clerk', 'supervisor', 'manager'));
$$;

-- Caller holds the loads row lock. Locks lm_loads and refuses a load a driver holds.
create function public._lm_reassign_guard(p_load public.loads) returns void
language plpgsql security definer set search_path = public as $$
declare m lm_loads;
begin
  if p_load.check_status is distinct from 'confirmed' then
    raise exception '% is not checker-confirmed yet, so it is not invoiced; use the normal load tools', p_load.load_nbr;
  end if;
  select * into m from lm_loads where load_id = p_load.id for update;
  if found and (m.token_hash is not null or m.status <> 'ready') then
    raise exception '% has been claimed by % (%). Unassign it in Control Tower first, then change the trucker',
      p_load.load_nbr, coalesce(m.claimed_name, 'a driver'), m.status;
  end if;
end $$;

-- Record the new deliverer for the invoices behind these shipments.
create function public._lm_note_deliver_via(p_load public.loads, p_shipments text[], p_from_via text,
                                            p_via text, p_reason text, p_invoices text[] default null) returns text[]
language plpgsql security definer set search_path = public as $$
declare r record; out text[] := '{}';
begin
  if p_load.env <> 'live' then return out; end if;       -- invoices exist for the live tenant only
  for r in
    select i.reference_number nbr, i.ship_via orig, i.status, min(s.shipment_nbr) shipment_nbr
      from unnest(p_shipments) n
      join shipments s on s.shipment_nbr = n
      join invoices i on i.order_number = s.order_nbr
      left join invoice_deliver_via o on o.invoice_nbr = i.reference_number
     where coalesce(o.deliver_via, i.ship_via) = p_from_via
       and (case when p_invoices is not null then i.reference_number = any (p_invoices)
                 else i.invoice_date >= p_load.load_date end)   -- default: not older invoices of the same order
     group by i.reference_number, i.ship_via, i.status
  loop
    insert into invoice_deliver_via (invoice_nbr, env, shipment_nbr, load_id, load_nbr, original_via, deliver_via,
                                     reason, set_by_name, acu_state, acu_detail)
    values (r.nbr, p_load.env, r.shipment_nbr, p_load.id, p_load.load_nbr, r.orig, p_via, p_reason, dispatch_actor_name(),
            case when r.status = 'Closed' then 'skipped' else 'pending' end,
            case when r.status = 'Closed' then 'Invoice already Closed in Acumatica' end)
    on conflict (invoice_nbr) do update
       set shipment_nbr = excluded.shipment_nbr, load_id = excluded.load_id, load_nbr = excluded.load_nbr,
           deliver_via = excluded.deliver_via, reason = excluded.reason, set_by = auth.uid(),
           set_by_name = excluded.set_by_name, set_at = now(),
           acu_state = excluded.acu_state, acu_detail = excluded.acu_detail, acu_at = null;
    out := out || r.nbr;
  end loop;
  return out;
end $$;

create function public._lm_reassign_log(p_load public.loads, p_note text, p_detail jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into load_events (load_id, env, load_nbr, kind, note, ship_via, detail, actor_name)
  values (p_load.id, p_load.env, p_load.load_nbr, 'reassign', p_note, p_load.ship_via, p_detail, dispatch_actor_name());
  if exists (select 1 from lm_loads where load_id = p_load.id) then
    update loads set sheet_stale_at = now() where id = p_load.id;
    perform _lm_event(p_load.id, 'reassign', 'office', p_actor := dispatch_actor_name(), p_payload := p_detail);
  end if;
end $$;

-- ------------------------------------------------------------------
-- Full reassignment
-- ------------------------------------------------------------------
create function public.lm_reassign_load(p_load_id bigint, p_ship_via text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l loads; n loads; nbrs text[]; invs text[]; why text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if auth.uid() is null or not _lm_can_reassign() then
    raise exception 'Only the Trucker Liaison, a supervisor or a manager can change a trucker' using errcode = '42501';
  end if;
  if why is null then raise exception 'Say why the trucker is changing'; end if;
  p_ship_via := nullif(btrim(coalesce(p_ship_via, '')), '');
  if p_ship_via is null or p_ship_via ilike 'BATCH%' or not exists (select 1 from ship_via_codes where ship_via = p_ship_via) then
    raise exception 'Pick a real Ship Via';
  end if;

  select * into l from loads where id = p_load_id for update;
  if not found then raise exception 'Load not found'; end if;
  if l.ship_via is not distinct from p_ship_via then raise exception '% is already on %', l.load_nbr, p_ship_via; end if;
  perform _lm_reassign_guard(l);

  select array_agg(shipment_nbr order by shipment_nbr) into nbrs from load_shipments where load_id = l.id;
  update loads set ship_via = p_ship_via, contractor = null where id = l.id returning * into n;
  invs := _lm_note_deliver_via(n, coalesce(nbrs, '{}'), l.ship_via, p_ship_via, why);
  perform _lm_reassign_log(n, 'Trucker changed from ' || coalesce(l.ship_via, '—') || ' to ' || p_ship_via || ': ' || why,
    jsonb_build_object('mode', 'full', 'from_via', l.ship_via, 'to_via', p_ship_via, 'reason', why,
                       'was_contractor', l.contractor, 'shipments', to_jsonb(nbrs), 'invoices', to_jsonb(invs)));
  return jsonb_build_object('load_id', n.id, 'load_nbr', n.load_nbr, 'ship_via', n.ship_via,
                            'invoices', coalesce(cardinality(invs), 0), 'reprint', true);
end $$;

-- ------------------------------------------------------------------
-- Partial reassignment
-- ------------------------------------------------------------------
create function public.lm_reassign_shipments(p_shipments text[], p_ship_via text, p_reason text,
                                             p_target_load bigint default null,
                                             p_invoices text[] default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  why   text := nullif(btrim(coalesce(p_reason, '')), '');
  src loads; t loads; first_src loads;
  nbrs  text[]; mine text[];
  env_  text;
  invs  text[] := '{}'; more text[];
  made  boolean := false;
  touched bigint[] := '{}';
begin
  if auth.uid() is null or not _lm_can_reassign() then
    raise exception 'Only the Trucker Liaison, a supervisor or a manager can change a trucker' using errcode = '42501';
  end if;
  if why is null then raise exception 'Say why the trucker is changing'; end if;
  select array_agg(distinct x) into nbrs from unnest(coalesce(p_shipments, '{}')) x where nullif(btrim(x), '') is not null;
  if coalesce(cardinality(nbrs), 0) = 0 then raise exception 'Tick at least one shipment'; end if;
  p_ship_via := nullif(btrim(coalesce(p_ship_via, '')), '');
  if p_ship_via is null or p_ship_via ilike 'BATCH%' or not exists (select 1 from ship_via_codes where ship_via = p_ship_via) then
    raise exception 'Pick a real Ship Via';
  end if;
  perform pg_advisory_xact_lock(hashtext('lm_reassign'));

  -- Every shipment must be on a load, all in one env.
  if (select count(*) from load_shipments where shipment_nbr = any (nbrs)) <> cardinality(nbrs) then
    raise exception 'Some of those shipments are not on a load';
  end if;
  select min(env) into env_ from load_shipments where shipment_nbr = any (nbrs);
  if (select count(distinct env) from load_shipments where shipment_nbr = any (nbrs)) > 1 then
    raise exception 'Shipments from test and live can''t be mixed';
  end if;

  -- Lock the source loads (id order), check each, and keep one from being emptied.
  for src in select l.* from loads l where l.id in (select load_id from load_shipments where shipment_nbr = any (nbrs) and env = env_)
              order by l.id for update
  loop
    if first_src.id is null then first_src := src; end if;
    if src.ship_via is not distinct from p_ship_via then raise exception '% is already on %', src.load_nbr, p_ship_via; end if;
    perform _lm_reassign_guard(src);
    if not exists (select 1 from load_shipments where load_id = src.id and shipment_nbr <> all (nbrs)) then
      raise exception 'That would move every shipment off %. Use "Change trucker for the whole load" instead', src.load_nbr;
    end if;
  end loop;

  -- The target.
  if p_target_load is not null then
    select * into t from loads where id = p_target_load for update;
    if not found or t.env <> env_ then raise exception 'Target load not found'; end if;
    if t.ship_via is distinct from p_ship_via then raise exception '% is on %, not %', t.load_nbr, t.ship_via, p_ship_via; end if;
    if t.id = any (select load_id from load_shipments where shipment_nbr = any (nbrs)) then
      raise exception 'Some of those shipments are already on %', t.load_nbr;
    end if;
    perform _lm_reassign_guard(t);
  else
    select l.* into t from loads l
     where l.env = env_ and l.load_date = first_src.load_date and l.ship_via = p_ship_via
       and l.check_status = 'confirmed' and l.status in ('done', 'partial')
       and not exists (select 1 from lm_loads m where m.load_id = l.id and (m.token_hash is not null or m.status <> 'ready'))
     order by l.id desc limit 1 for update;
    if found then
      perform _lm_reassign_guard(t);
    else
      insert into loads (env, load_date, wave, seq, load_nbr, status, ship_via, truck_type, source, applied_at,
                         check_status, checked_by, checked_at, checker_done_at, checker_done_by, checker_done_name,
                         notes, created_by)
      values (env_, first_src.load_date, first_src.wave, 0, '', 'done', p_ship_via, first_src.truck_type, 'reassign', now(),
              'confirmed', first_src.checked_by, first_src.checked_at, first_src.checker_done_at, first_src.checker_done_by,
              first_src.checker_done_name, 'Split from ' || first_src.load_nbr || ': ' || why, auth.uid())
      returning * into t;
      made := true;
      insert into load_events (load_id, env, load_nbr, kind, note, ship_via, detail, actor_name)
      values (t.id, t.env, t.load_nbr, 'create', 'Created by trucker reassignment from ' || first_src.load_nbr, p_ship_via,
              jsonb_build_object('shipments', to_jsonb(nbrs)), dispatch_actor_name());
    end if;
  end if;

  -- Move, source by source, so each gets its own audit row.
  for src in select l.* from loads l where l.id in (select load_id from load_shipments where shipment_nbr = any (nbrs) and env = env_)
              order by l.id
  loop
    select array_agg(shipment_nbr order by shipment_nbr) into mine from load_shipments
     where load_id = src.id and shipment_nbr = any (nbrs);   -- this source's share
    update load_shipments set load_id = t.id where env = env_ and load_id = src.id and shipment_nbr = any (mine);
    update check_lines set load_id = t.id where load_id = src.id and shipment_nbr = any (mine);
    more := _lm_note_deliver_via(t, mine, src.ship_via, p_ship_via, why, p_invoices);
    invs := invs || more;
    touched := touched || src.id;
    perform _lm_reassign_log(src, 'Moved ' || cardinality(mine) || ' shipment(s) to ' || t.load_nbr || ' (' || p_ship_via || '): ' || why,
      jsonb_build_object('mode', 'partial', 'role', 'source', 'from_via', src.ship_via, 'to_via', p_ship_via, 'to_load', t.load_nbr,
                         'reason', why, 'shipments', to_jsonb(mine), 'invoices', to_jsonb(more)));
  end loop;

  perform _lm_reassign_log(t, 'Received shipments from ' || (select string_agg(load_nbr, ', ') from loads where id = any (touched)) || ': ' || why,
    jsonb_build_object('mode', 'partial', 'role', 'target', 'to_via', p_ship_via, 'reason', why,
                       'from_loads', (select jsonb_agg(load_nbr) from loads where id = any (touched)),
                       'shipments', to_jsonb(nbrs), 'invoices', to_jsonb(invs)));
  return jsonb_build_object('target_load_id', t.id, 'target_load_nbr', t.load_nbr, 'created', made,
                            'source_load_ids', to_jsonb(touched), 'invoices', coalesce(cardinality(invs), 0), 'reprint', true);
end $$;

revoke all on function public._lm_can_reassign()                                       from public, anon, authenticated;
revoke all on function public._lm_reassign_guard(public.loads)                         from public, anon, authenticated;
revoke all on function public._lm_note_deliver_via(public.loads, text[], text, text, text, text[]) from public, anon, authenticated;
revoke all on function public._lm_reassign_log(public.loads, text, jsonb)              from public, anon, authenticated;
revoke all on function public.lm_reassign_load(bigint, text, text)                     from public, anon;
revoke all on function public.lm_reassign_shipments(text[], text, text, bigint, text[])        from public, anon;
grant execute on function public.lm_reassign_load(bigint, text, text)                  to authenticated;
grant execute on function public.lm_reassign_shipments(text[], text, text, bigint, text[])     to authenticated;

-- lm_sheet is the printed sheet: printing clears the reprint flag (otherwise as in 20261022210000_lm_claim.sql).
create or replace function public.lm_sheet(p_load_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare code text; l loads; units numeric;
begin
  code := lm_ensure_load(p_load_id);     -- checks the role and that the checker has confirmed it
  update loads set sheet_stale_at = null where id = p_load_id and sheet_stale_at is not null;
  select * into l from loads where id = p_load_id;
  select coalesce(sum(coalesce(cl.final_qty, sl.shipped_qty)), 0) into units
    from load_shipments ls
    join shipment_lines sl on sl.env = l.env and sl.shipment_nbr = ls.shipment_nbr
    left join check_lines cl on cl.load_id = l.id and cl.shipment_nbr = sl.shipment_nbr and cl.line_nbr = sl.line_nbr
   where ls.load_id = l.id and coalesce(cl.final_qty, sl.shipped_qty) > 0;
  return jsonb_build_object(
    'code', code, 'load_nbr', l.load_nbr, 'load_date', l.load_date, 'wave', l.wave, 'env', l.env,
    'ship_via', l.ship_via, 'trucker', (select description from ship_via_codes where ship_via = l.ship_via),
    'truck_type', l.truck_type, 'units', units,
    'stops', coalesce((
      select jsonb_agg(jsonb_build_object(
               'seq', r.seq, 'customer_id', r.customer_id, 'customer_name', r.customer_name, 'city', r.city, 'zone', r.zone,
               'shipments', (select coalesce(jsonb_agg(ls.shipment_nbr order by ls.shipment_nbr), '[]'::jsonb)
                               from load_shipments ls
                               join lateral (select * from _dispatch_shipments(l.env) x where x.shipment_nbr = ls.shipment_nbr) s on true
                              where ls.load_id = l.id and coalesce(s.customer_id, '?') = r.customer_id))
             order by r.seq)
        from _lm_stop_rows(p_load_id) r), '[]'::jsonb));
end $$;

-- Rollback (by hand):
-- drop function public.lm_reassign_shipments(text[], text, text, bigint, text[]);
-- drop function public.lm_reassign_load(bigint, text, text);
-- drop function public._lm_reassign_log(public.loads, text, jsonb);
-- drop function public._lm_note_deliver_via(public.loads, text[], text, text, text, text[]);
-- drop function public._lm_reassign_guard(public.loads);
-- drop function public._lm_can_reassign();
-- drop table public.invoice_deliver_via;
-- alter table public.loads drop column sheet_stale_at;   -- and restore lm_sheet from 20261022210000_lm_claim.sql
-- alter table public.loads drop constraint loads_source_check;   -- after deleting source = 'reassign' loads
-- alter table public.loads add constraint loads_source_check check (source in ('clerk', 'acumatica', 'invoice'));
