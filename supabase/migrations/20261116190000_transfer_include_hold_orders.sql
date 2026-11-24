-- 2026-11-16. Transfer lists also count On Hold and Credit Hold sales orders (Joel).
-- Only the status filter changes; the function signature and everything else is as in 20261113140000_transfer_window_since_last.sql.
-- Rollback: put the status filter back to ('Open', 'Back Order').
create or replace function public._dispatch_transfer_orders(p_from timestamptz, p_horizon_hours int, p_to timestamptz,
                                                 p_env text default null, p_carry boolean default false)
returns table (order_nbr text, customer_name text, status text, created_on timestamptz, sched_shipment date, far_dated boolean, late boolean)
language sql stable security definer set search_path = public as $$
  select o.order_nbr::text, o.customer_name::text, o.status::text, o.created_on::timestamptz, o.sched_shipment::date,
         (o.sched_shipment is not null
          and o.sched_shipment::timestamp > (p_to at time zone 'America/Jamaica') + make_interval(hours => greatest(p_horizon_hours, 0))),
         (o.created_on::timestamptz <= p_from)
    from sales_orders o
   where o.order_type = 'SO' and o.status in ('Open', 'Back Order', 'On Hold', 'Credit Hold')
     and o.created_on::timestamptz <= p_to
     and (o.created_on::timestamptz > p_from
          or (p_carry and o.created_on::timestamptz > p_from - interval '12 hours'
              and not exists (select 1 from transfer_list_orders x join transfer_lists t on t.id = x.list_id
                               where t.env = p_env and x.order_nbr = o.order_nbr)));
$$;
revoke all on function public._dispatch_transfer_orders(timestamptz, int, timestamptz, text, boolean) from public, anon, authenticated;
