-- Rank the trucker dropdown by invoiced orders over the last 12 months (so_invoices has
-- ~9 months of history and a Ship Via on 99.9% of rows), plus shipments not yet invoiced
-- (not Completed, last 14 days) so today's work counts too. Never-used codes last;
-- BATCH placeholders and cancelled invoices excluded.
create or replace function public.dispatch_ship_via_ranked()
returns table (ship_via text, description text, ships int, last_used date)
language sql stable security definer set search_path = public as $$
  with u as (
    select i.ship_via, i.invoice_date::date d from so_invoices i
     where i.invoice_date >= current_date - 365 and i.status <> 'Canceled' and coalesce(i.ship_via, '') <> ''
    union all
    select s.ship_via, s.shipment_date from shipments s
     where s.shipment_date >= current_date - 14 and s.operation = 'Issue' and s.status <> 'Completed' and coalesce(s.ship_via, '') <> ''
  ), a as (select u.ship_via, count(*) n, max(u.d) last_used from u group by 1)
  select c.ship_via, c.description, coalesce(a.n, 0)::int, a.last_used
    from ship_via_codes c left join a on a.ship_via = c.ship_via
   where dispatch_has_role() and c.ship_via not ilike 'BATCH%'
   order by coalesce(a.n, 0) desc, c.ship_via;
$$;
