-- Sales Orders tab: show the lines' Ship On date (sales_orders.sched_shipment). Acumatica only puts a line on a
-- shipment once its Ship On date has arrived, so the tab needs it to flag orders that can't be shipped yet.
drop function if exists public.dispatch_sales_orders(text[], integer);

create function public.dispatch_sales_orders(p_statuses text[] default array['Open'::text, 'Back Order'::text], p_days integer default 90)
 returns table(order_nbr text, status text, order_date date, requested_on date, sched_shipment date, customer_id text, customer_name text, shipping_zone text, order_total numeric, lines integer, open_lines integer, open_qty numeric, open_volume numeric, short_lines integer, open_shipments integer)
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
begin
  if not dispatch_has_role('batcher') then
    raise exception 'Your account doesn''t have the coordinator role' using errcode = '42501';
  end if;
  return query
  with i as (
    select it.order_nbr n, count(*)::int lines, count(*) filter (where it.open_qty > 0)::int open_lines,
           coalesce(sum(it.open_qty) filter (where it.open_qty > 0), 0) oq,
           coalesce(sum(it.open_qty * coalesce(it.volume, 0)) filter (where it.open_qty > 0), 0) ov,
           count(*) filter (where it.open_qty > 0 and it.open_qty > coalesce(it.qty_on_hand_71, 0))::int sh
      from so_ordered_items it where it.order_type = 'SO' group by 1
  ), s as (
    select o2 n, count(*)::int c
      from shipments sh, lateral unnest(string_to_array(sh.order_nbr, ', ')) o2
     where sh.status in ('Open', 'On Hold') and sh.operation = 'Issue' group by 1
  )
  select o.order_nbr::text, o.status::text, o.order_date::date, o.requested_on::date, o.sched_shipment::date, o.customer::text,
         o.customer_name::text, o.shipping_zone::text, o.order_total::numeric,
         coalesce(i.lines, 0), coalesce(i.open_lines, 0), coalesce(i.oq, 0)::numeric, coalesce(i.ov, 0)::numeric,
         coalesce(i.sh, 0), coalesce(s.c, 0)
    from sales_orders o
    left join i on i.n = o.order_nbr
    left join s on s.n = o.order_nbr
   where o.order_type = 'SO' and o.status = any (p_statuses)
     and o.order_date >= current_date - greatest(p_days, 1)
   order by o.order_date desc, o.order_nbr desc;
end $function$;

revoke all on function public.dispatch_sales_orders(text[], int) from public, anon;
grant execute on function public.dispatch_sales_orders(text[], int) to authenticated;
