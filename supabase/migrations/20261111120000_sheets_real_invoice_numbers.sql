-- Check-off sheets and load sheet showed shipment numbers in the Invoice column: lm_stop_invoices.invoice_nbr is
-- almost never filled, so the pages fell back to the shipment number. Look the real invoice number(s) up from
-- so_invoices via the shipment's sales order instead. If the order has invoices dated the load date, only those are
-- shown (an order can carry earlier/later invoices); otherwise all of the order's invoices. Null = not invoiced yet.
create or replace function public._lm_invoice_nbrs(p_shipment text, p_load_date date) returns text
language sql stable security definer set search_path = public as $$
  select string_agg(distinct i.reference_number, ', ')
    from so_invoices i
   where i.order_number = (select s.order_nbr from shipments s where s.shipment_nbr = p_shipment limit 1)
     and (i.invoice_date = p_load_date
          or not exists (select 1 from so_invoices j
                          where j.order_number = i.order_number and j.invoice_date = p_load_date));
$$;
revoke all on function public._lm_invoice_nbrs(text, date) from public, anon, authenticated;

-- lm_check_sheet: only the invoice_nbr expression changes (otherwise as in 20261110150000_check_sheet_farthest.sql).
create or replace function public.lm_check_sheet(p_load_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l loads;
begin
  if auth.uid() is null or not dispatch_has_role() then
    raise exception 'Your account doesn''t have a dispatch role' using errcode = '42501';
  end if;
  select * into l from loads where id = p_load_id;
  if not found then raise exception 'Load not found'; end if;
  return jsonb_build_object(
    'load_nbr', l.load_nbr, 'load_date', l.load_date, 'wave', l.wave, 'env', l.env,
    'ship_via', l.ship_via, 'trucker', (select description from ship_via_codes where ship_via = l.ship_via),
    'truck_type', l.truck_type, 'check_status', l.check_status,
    'farthest', (select jsonb_build_object('zone', d.zone, 'label', d.label, 'km', d.km)
                   from _lm_stop_rows(p_load_id) r join zone_distance d on d.zone = upper(btrim(r.zone))
                  order by d.km desc, d.zone limit 1),
    'stops', coalesce((
      select jsonb_agg(jsonb_build_object(
               'seq', r.seq, 'customer_id', r.customer_id, 'customer_name', r.customer_name,
               'address', r.address, 'city', r.city, 'phone', r.phone, 'zone', r.zone,
               'shipments', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'shipment_nbr', ls.shipment_nbr,
                          'invoice_nbr', coalesce(
                              (select i.invoice_nbr from lm_stop_invoices i join lm_stops st on st.id = i.stop_id
                                where st.load_id = l.id and i.shipment_nbr = ls.shipment_nbr and i.invoice_nbr is not null limit 1),
                              _lm_invoice_nbrs(ls.shipment_nbr, l.load_date)),
                          'lines', (select coalesce(jsonb_agg(jsonb_build_object(
                                             'line_nbr', sl.line_nbr, 'inventory_id', sl.inventory_id, 'description', sl.description,
                                             'uom', sl.uom, 'qty', coalesce(cl.final_qty, sl.shipped_qty)) order by sl.line_nbr), '[]'::jsonb)
                                      from shipment_lines sl
                                      left join check_lines cl on cl.load_id = l.id and cl.shipment_nbr = sl.shipment_nbr and cl.line_nbr = sl.line_nbr
                                     where sl.env = l.env and sl.shipment_nbr = ls.shipment_nbr
                                       and coalesce(cl.final_qty, sl.shipped_qty) > 0)
                        ) order by ls.shipment_nbr), '[]'::jsonb)
                   from load_shipments ls
                   join lateral (select * from _dispatch_shipments(l.env) x where x.shipment_nbr = ls.shipment_nbr) s on true
                  where ls.load_id = l.id and coalesce(s.customer_id, '?') = r.customer_id))
             order by r.seq)
        from _lm_stop_rows(p_load_id) r), '[]'::jsonb));
end $$;

revoke all on function public.lm_check_sheet(bigint) from public, anon;
grant execute on function public.lm_check_sheet(bigint) to authenticated;

-- lm_sheet: add 'invoices' per stop (invoice numbers); 'shipments' stays for compatibility.
create or replace function public.lm_sheet(p_load_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare code text; l loads; units numeric;
begin
  code := lm_ensure_load(p_load_id);
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
                              where ls.load_id = l.id and coalesce(s.customer_id, '?') = r.customer_id),
               'invoices', (select coalesce(jsonb_agg(_lm_invoice_nbrs(ls.shipment_nbr, l.load_date) order by ls.shipment_nbr), '[]'::jsonb)
                               from load_shipments ls
                               join lateral (select * from _dispatch_shipments(l.env) x where x.shipment_nbr = ls.shipment_nbr) s on true
                              where ls.load_id = l.id and coalesce(s.customer_id, '?') = r.customer_id))
             order by r.seq)
        from _lm_stop_rows(p_load_id) r), '[]'::jsonb));
end $$;

-- Rollback (by hand): restore lm_check_sheet from 20261110150000_check_sheet_farthest.sql and lm_sheet from
-- 20261026120000_reassign_ship_via.sql; drop function public._lm_invoice_nbrs(text, date);
