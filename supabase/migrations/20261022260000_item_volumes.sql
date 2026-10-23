-- Volume per case for items, for the Sales Orders tab's TEST mode (dispatch-orders): TEST orders
-- carry no volume, so it comes from the same items on production orders. Service role only.
create or replace function public.dispatch_item_volumes(p_ids text[])
returns table (inventory_id text, volume numeric)
language sql stable security definer set search_path = public as $$
  select distinct on (i.inventory_id) i.inventory_id::text, i.volume::numeric
    from so_ordered_items i
   where i.inventory_id = any (p_ids) and i.volume is not null
   order by i.inventory_id, i.order_date desc;
$$;
revoke all on function public.dispatch_item_volumes(text[]) from public, anon, authenticated;
grant execute on function public.dispatch_item_volumes(text[]) to service_role;
