-- Load sheets for loads picked and invoiced OUTSIDE the portal (Joel, 2026-10-24).
--
-- During the hybrid period a trucker's run can be picked in the old system, invoiced in Acumatica
-- (shipments Completed, invoices Open) and never reach the portal, so it has no load and no
-- checker confirmation, so no load sheet and no driver claim.
--
-- The load-sheet clerk searches one invoice (or shipment) number on that run:
--   lm_invoice_search(nbr)       finds the invoice, then every other Open invoice with the same
--                                Ship Via and invoice date ("sister" invoices), and the Completed
--                                shipments behind them (invoices.order_number = shipments.order_nbr),
--                                each marked selectable or blocked with the reason.
--   lm_build_invoice_load(...)   builds a load from the ticked shipments, marks it confirmed (so the
--                                existing sheet / claim / Control Tower code works unchanged) and
--                                issues its claim code. Load number L-MMDD-ACU-NN, source 'invoice'.
--
-- Live only: invoices has no test copy.
-- Nothing is written to Acumatica. The load is flagged source = 'invoice' so the autoload sync
-- (which only touches source = 'acumatica') never edits it.
--
-- invoices has no shipment number, so shipments are matched through the order number. An order with
-- several invoices lists them all against each of its shipments; the sheet itself is per shipment.

alter table public.loads drop constraint loads_source_check;
alter table public.loads add constraint loads_source_check check (source in ('clerk', 'acumatica', 'invoice'));

create function public.lm_invoice_search(p_nbr text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  n    text := btrim(coalesce(p_nbr, ''));
  ord  text[];
  via  text;
  d    date;
  invs jsonb;
  ships jsonb;
begin
  if auth.uid() is null or not lm_staff() then
    raise exception 'Your account doesn''t have a dispatch role' using errcode = '42501';
  end if;
  if n = '' then raise exception 'Type an invoice or shipment number'; end if;

  -- The typed number: an invoice, else a shipment (-> its order's invoices).
  select array_agg(distinct i.order_number), min(i.ship_via), min(i.invoice_date)
    into ord, via, d
    from invoices i where i.reference_number = n;
  if ord is null then
    select array_agg(distinct i.order_number), min(i.ship_via), min(i.invoice_date)
      into ord, via, d
      from invoices i
     where i.order_number in (select s.order_nbr from shipments s where s.shipment_nbr = n);
  end if;
  if ord is null then
    return jsonb_build_object('found', false, 'nbr', n);
  end if;

  -- Sisters: Open invoices on the same Ship Via and date, plus the invoice(s) that were typed.
  select coalesce(jsonb_agg(jsonb_build_object(
           'reference_number', i.reference_number, 'order_number', i.order_number,
           'customer_name', i.customer_name, 'status', i.status, 'amount', i.invoice_amount,
           'typed', i.order_number = any (ord))
         order by i.customer_name, i.reference_number), '[]'::jsonb)
    into invs
    from invoices i
   where i.ship_via = via and i.invoice_date = d
     and (i.status = 'Open' or i.order_number = any (ord));

  select coalesce(jsonb_agg(row_to_json(x)::jsonb order by x.customer_name, x.shipment_nbr), '[]'::jsonb)
    into ships
    from (
      select s.shipment_nbr, s.order_nbr, s.customer_id, s.customer_name, s.status,
             (select coalesce(sum(sl.shipped_qty), 0) from shipment_lines sl
               where sl.env = 'live' and sl.shipment_nbr = s.shipment_nbr) as units,
             (select jsonb_agg(distinct i.reference_number) from invoices i
               where i.order_number = s.order_nbr and i.ship_via = via and i.invoice_date = d) as invoice_nbrs,
             ex.load_nbr as on_load,
             case
               when s.status <> 'Completed' then 'Still ' || s.status || ' in Acumatica'
               when not exists (select 1 from shipment_lines sl
                                 where sl.env = 'live' and sl.shipment_nbr = s.shipment_nbr and sl.shipped_qty > 0)
                    then 'Item lines not synced from Acumatica yet'
               when ex.load_nbr is not null and not ex.reusable then 'Already on ' || ex.load_nbr
             end as blocked
        from shipments s
        left join lateral (
          select l.load_nbr, (l.source = 'acumatica' and l.check_status is null) as reusable
            from load_shipments ls join loads l on l.id = ls.load_id
           where ls.env = 'live' and ls.shipment_nbr = s.shipment_nbr limit 1) ex on true
       where s.order_nbr in (select (j ->> 'order_number') from jsonb_array_elements(invs) j)
         and s.ship_via = via and s.operation = 'Issue' and coalesce(s.order_type, '') <> 'RC'
    ) x;

  return jsonb_build_object('found', true, 'nbr', n, 'ship_via', via,
    'trucker', (select description from ship_via_codes where ship_via = via),
    'invoice_date', d, 'invoices', invs, 'shipments', ships);
end $$;

create function public.lm_build_invoice_load(p_ship_via text, p_shipments text[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  d    date := (now() at time zone 'America/Jamaica')::date;
  n    text;
  s    shipments;
  ex   record;
  l    loads;
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

  -- Completed shipments left on an unchecked auto-load are taken over (the sync deletes the empty load).
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

revoke all on function public.lm_invoice_search(text)                from public, anon;
revoke all on function public.lm_build_invoice_load(text, text[])    from public, anon;
grant execute on function public.lm_invoice_search(text)             to authenticated;
grant execute on function public.lm_build_invoice_load(text, text[]) to authenticated;

-- Rollback (by hand):
-- drop function public.lm_build_invoice_load(text, text[]);
-- drop function public.lm_invoice_search(text);
-- alter table public.loads drop constraint loads_source_check;
-- alter table public.loads add constraint loads_source_check check (source in ('clerk', 'acumatica'));  -- after deleting source = 'invoice' loads
