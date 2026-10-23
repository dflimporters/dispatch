-- Day 0 backlog plan (day0.html, a standalone page that is not linked from the hub nav).
-- One JSON array with a row per open order line for the chosen statuses: what is still to ship,
-- its case volume, and stock at 71. The page does the allocation, transfer and truck maths.
-- Returned as one jsonb value so PostgREST's row limit doesn't cut the backlog off.
create or replace function public.dispatch_day0_lines(p_statuses text[] default array['Open', 'Back Order'])
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not dispatch_has_role('batcher') then
    raise exception 'Your account doesn''t have the coordinator role' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'order_nbr', o.order_nbr, 'status', o.status, 'order_date', o.order_date,
             'customer', o.customer, 'customer_name', o.customer_name,
             'zone', o.shipping_zone, 'city', i.city,
             'item', i.inventory_id, 'descr', i.line_description,
             'open_qty', i.open_qty, 'volume', coalesce(i.volume, 0),
             'on_hand_71', coalesce(i.qty_on_hand_71, 0), 'synced_at', i.synced_at)
           order by o.order_date, o.order_nbr, i.line_nbr)
      from sales_orders o
      join so_ordered_items i on i.order_nbr = o.order_nbr and i.order_type = 'SO'
     where o.order_type = 'SO' and o.status = any (p_statuses) and i.open_qty > 0
  ), '[]'::jsonb);
end $$;
revoke all on function public.dispatch_day0_lines(text[]) from public, anon;
grant execute on function public.dispatch_day0_lines(text[]) to authenticated;
