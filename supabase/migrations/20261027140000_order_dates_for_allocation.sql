-- Short-pick allocation (docs/short-pick-allocation.md): Invoicing fills the oldest sales order
-- first, so it needs each order's date. Read-only; any dispatch role.
-- Rollback: drop function public.dispatch_order_dates(text[]);
create or replace function public.dispatch_order_dates(p_orders text[])
returns table (order_nbr text, order_date date)
language plpgsql stable security definer set search_path = public as $$
begin
  if not dispatch_has_role() then raise exception 'Your account has no dispatch role' using errcode = '42501'; end if;
  return query
  select o.order_nbr::text, o.order_date::date from sales_orders o
   where o.order_type = 'SO' and o.order_nbr = any (p_orders);
end $$;
revoke all on function public.dispatch_order_dates(text[]) from public, anon;
grant execute on function public.dispatch_order_dates(text[]) to authenticated;
