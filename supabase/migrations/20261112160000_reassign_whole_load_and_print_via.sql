-- Add a WHOLE load onto an existing load of another trucker (Joel, 2026-11-12).
-- lm_reassign_shipments gains p_whole: the source load may be emptied (all its shipments move to the
-- target, which is then required). The emptied load stays as a record with no shipments; the Load
-- Sheets page hides loads that have none.
--
-- Print fix: invoice_print_fetch now reports the CURRENT trucker, not the Ship Via Acumatica had when the
-- invoice was synced: the Ship Via of the load the invoice's shipment is on now, else the DELIVERVIA
-- recorded when it was reassigned, else the synced one.

drop function public.lm_reassign_shipments(text[], text, text, bigint, text[]);

create function public.lm_reassign_shipments(p_shipments text[], p_ship_via text, p_reason text,
                                             p_target_load bigint default null,
                                             p_invoices text[] default null,
                                             p_whole boolean default false) returns jsonb
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
  if p_whole and p_target_load is null then raise exception 'Pick the load to add it to'; end if;
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
    if not p_whole and not exists (select 1 from load_shipments where load_id = src.id and shipment_nbr <> all (nbrs)) then
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

revoke all on function public.lm_reassign_shipments(text[], text, text, bigint, text[], boolean) from public, anon;
grant execute on function public.lm_reassign_shipments(text[], text, text, bigint, text[], boolean) to authenticated;

create or replace function public.invoice_print_fetch(p_refs text[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not (dispatch_has_role('supervisor') or dispatch_has_role('manager')) then
    raise exception 'Only a supervisor can print invoices' using errcode = '42501';
  end if;
  if p_refs is null or coalesce(array_length(p_refs, 1), 0) = 0 then raise exception 'Nothing to fetch'; end if;
  if array_length(p_refs, 1) > 200 then raise exception 'Fetch at most 200 invoices at a time'; end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'ref',            h.ref,
        'doc_type',       h.doc_type,
        'date',           to_char(h.doc_date, 'YYYY-MM-DD'),
        'due_date',       to_char(h.due_date, 'YYYY-MM-DD'),
        'status',         h.status,
        'customer_id',    h.customer_id,
        'currency',       h.currency,
        'terms',          h.terms,
        'salesperson',    h.salesperson,
        'so_number',      h.so_number,
        'shipment_nbr',   h.shipment_nbr,
        'customer_po',    h.customer_po,
        'customer_ref',   h.customer_ref,
        'ship_via',       coalesce(
                            (select l2.ship_via from load_shipments ls2 join loads l2 on l2.id = ls2.load_id
                              where ls2.env = 'live' and ls2.shipment_nbr = h.shipment_nbr
                                and l2.ship_via is not null and l2.ship_via not ilike 'BATCH%'
                              order by l2.id desc limit 1),
                            (select d.deliver_via from invoice_deliver_via d where d.invoice_nbr = h.ref),
                            h.ship_via),
        'bill',           h.bill,
        'ship',           h.ship,
        'sales_total',    h.sales_total,
        'discount_total', h.discount_total,
        'tax_total',      h.tax_total,
        'total',          h.total,
        'lines', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'n',          l.line_nbr,
              'item',       l.inventory_cd,
              'descr',      l.descr,
              'qty',        l.qty,
              'uom',        l.uom,
              'unit_price', l.unit_price,
              'tax_cat',    l.tax_cat,
              'amount',     l.amount,
              'discount',   l.discount,
              'note',       l.note
            ) order by l.line_nbr)
            from invoice_print_lines l where l.ref = h.ref
        ), '[]'::jsonb)
      ) order by h.ref)
    from invoice_print_headers h
   where h.ref = any (p_refs)
  ), '[]'::jsonb);
end $$;
