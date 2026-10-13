-- Truckers for the liaison's dropdown: every real Ship Via code (not the BATCH
-- placeholders), most active over the last 12 months first, never-used last.
create function public.dispatch_ship_via_ranked()
returns table (ship_via text, description text, ships int, last_used date)
language sql stable security definer set search_path = public as $$
  select c.ship_via, c.description, coalesce(a.n, 0)::int, a.last_used
    from ship_via_codes c
    left join (select s.ship_via, count(*) n, max(s.shipment_date) last_used
                 from shipments s where s.shipment_date >= current_date - 365 and s.operation = 'Issue'
                group by s.ship_via) a on a.ship_via = c.ship_via
   where dispatch_has_role() and c.ship_via not ilike 'BATCH%'
   order by coalesce(a.n, 0) desc, c.ship_via;
$$;
revoke all on function public.dispatch_ship_via_ranked() from public, anon;
grant execute on function public.dispatch_ship_via_ranked() to authenticated;
