-- Shipment value showed 0 on a third of open shipments (e.g. 281493 on L-1023-PM-06).
-- Their order lines ARE in so_ordered_items with prices, but the live line sync
-- (dispatch-acu sync_live_lines) left shipment_lines.unit_price null for them.
-- Likely cause: it looks prices up with .in('order_nbr', 200 orders), and one PostgREST
-- response is capped (1000 rows by default), so orders late in each batch get no price.
--
-- dispatch_reprice_live() fills every unpriced live line from so_ordered_items in SQL and
-- re-sums shipment_value for the shipments it touched. Same rule as the edge function:
-- unit = ext_price / order_qty when order_qty > 0, else unit_price; missing price = 0.
-- It runs every minute because the 5-minute line sync overwrites those lines with null
-- again each cycle until the edge function is fixed to page its price lookup.

create or replace function public.dispatch_reprice_live() returns jsonb
language plpgsql security definer set search_path = public as $$
declare lines_n int; ships_n int;
begin
  create temp table _rp on commit drop as
    with p as (
      select distinct on (order_type, order_nbr, line_nbr) order_type, order_nbr, line_nbr,
             case when order_qty > 0 then coalesce(ext_price, 0) / order_qty else coalesce(unit_price, 0) end unit
        from so_ordered_items order by order_type, order_nbr, line_nbr
    ), u as (
      update shipment_lines sl
         set unit_price = p.unit, line_value = round(coalesce(sl.shipped_qty, 0) * p.unit, 2)
        from p
       where sl.env = 'live' and sl.unit_price is null
         and p.order_type = sl.order_type and p.order_nbr = sl.order_nbr and p.line_nbr = sl.order_line_nbr
      returning sl.shipment_nbr
    ) select distinct shipment_nbr from u;
  select count(*) into ships_n from _rp;
  update shipments s set shipment_value = t.v
    from (select sl.shipment_nbr, round(sum(coalesce(sl.line_value, 0)), 2) v
            from shipment_lines sl where sl.env = 'live' and sl.shipment_nbr in (select shipment_nbr from _rp)
           group by 1) t
   where s.shipment_nbr = t.shipment_nbr;
  return jsonb_build_object('shipments_repriced', ships_n);
end $$;
revoke all on function public.dispatch_reprice_live() from public, anon, authenticated;

select cron.schedule('dispatch-reprice-1min', '* * * * *', $cron$ select public.dispatch_reprice_live() $cron$);
