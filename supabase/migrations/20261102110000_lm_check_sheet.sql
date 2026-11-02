-- Trucker check-off sheet: stops, invoices and every item line of a load, for the printed summary
-- and detailed versions (loadsheet.html). Read-only. Quantities are what is going out: the
-- checker's final qty where there is one, else the shipment's own; zero lines are left off.
-- Unlike lm_sheet it works at any stage of the load and does not create the driver claim code.
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
    'stops', coalesce((
      select jsonb_agg(jsonb_build_object(
               'seq', r.seq, 'customer_id', r.customer_id, 'customer_name', r.customer_name,
               'address', r.address, 'city', r.city, 'phone', r.phone, 'zone', r.zone,
               'shipments', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'shipment_nbr', ls.shipment_nbr,
                          'invoice_nbr', (select i.invoice_nbr from lm_stop_invoices i join lm_stops st on st.id = i.stop_id
                                           where st.load_id = l.id and i.shipment_nbr = ls.shipment_nbr limit 1),
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

-- Rollback (by hand): drop function public.lm_check_sheet(bigint);
