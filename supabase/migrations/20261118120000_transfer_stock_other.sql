-- 2026-11-18. Stock held outside 71 and Ashenheim, for the transfer list (Joel).
-- The Acumatica GI only gives per-warehouse stock for 71 and Ashenheim, plus TotalQOHAllwarehouses (so_ordered_items.qty_on_hand).
-- Other warehouses = total - 71 - Ashenheim. Until their stock is synced individually, this tells the coordinator whether
-- an item with none at Ashenheim exists in some other warehouse or is out of stock everywhere.
-- Rollback: drop function public.dispatch_transfer_stock_other(text[]).
create or replace function public.dispatch_transfer_stock_other(p_ids text[])
returns table (inventory_id text, on_hand_total numeric, on_hand_other numeric)
language sql stable security definer set search_path = public as $$
  select x.inventory_id, x.tot, greatest(x.tot - x.oh71 - x.ohash, 0)
    from (select distinct on (o.inventory_id) o.inventory_id::text inventory_id, o.qty_on_hand::numeric tot,
                 coalesce(o.qty_on_hand_71, 0) oh71, coalesce(o.qty_on_hand_ash, 0) ohash
            from so_ordered_items o
           where o.inventory_id = any(p_ids) and o.qty_on_hand is not null and o.synced_at > now() - interval '2 days'
           order by o.inventory_id, o.synced_at desc) x
   where dispatch_has_role('batcher');
$$;
revoke all on function public.dispatch_transfer_stock_other(text[]) from public, anon;
grant execute on function public.dispatch_transfer_stock_other(text[]) to authenticated;
