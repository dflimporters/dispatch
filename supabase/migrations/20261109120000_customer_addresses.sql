-- Delivery address per customer (from the customers table synced from Acumatica), so the
-- coordinator and Sales Orders screens can show where each drop is and group loads by area.
create or replace function public.dispatch_customer_addresses()
returns table (customer_id text, address text, city text)
language sql stable security definer set search_path = public as $$
  select c.customer_id::text,
         nullif(btrim(concat_ws(', ', nullif(btrim(c.address_line1), ''), nullif(btrim(c.address_line2), ''))), '')::text,
         nullif(btrim(c.city), '')::text
    from customers c;
$$;
revoke all on function public.dispatch_customer_addresses() from public, anon;
grant execute on function public.dispatch_customer_addresses() to authenticated;
