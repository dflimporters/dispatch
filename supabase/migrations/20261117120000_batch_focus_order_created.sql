-- 2026-11-17. Batcher focus: when each order was created, so the batcher page can tag which shipments belong
-- to today's batching (orders placed before 2pm on the previous working day) and which are next cycle.
-- Read-only; coordinator role only. Rollback: drop function public.dispatch_order_created(text[]).
create or replace function public.dispatch_order_created(p_nbrs text[])
returns table (order_nbr text, created_on timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not dispatch_has_role('batcher') then raise exception 'Your account doesn''t have the coordinator role' using errcode = '42501'; end if;
  return query
  select o.order_nbr::text, o.created_on::timestamptz
    from sales_orders o
   where o.order_type = 'SO' and o.order_nbr = any (p_nbrs);
end $$;
revoke all on function public.dispatch_order_created(text[]) from public, anon;
grant execute on function public.dispatch_order_created(text[]) to authenticated;
