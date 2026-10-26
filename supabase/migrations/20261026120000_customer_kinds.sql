-- Pickup / donation / promotion customers, so the office and warehouse screens can separate
-- them from normal delivery orders.
--
-- Acumatica has no pickup or donation customer class (only PROMOTION), so:
--   promotion  any customer whose Acumatica customer_class = 'PROMOTION' (automatic)
--   pickup /
--   donation   listed by hand in customer_kind_overrides (seeded below; add or remove rows as needed)
-- An override wins over the class. Shipments on the PICKUPTRK* ship vias are also treated as
-- pickup by the pages themselves (client side), whatever the customer.
create table if not exists public.customer_kind_overrides (
  customer_id text primary key,
  kind        text not null check (kind in ('pickup', 'donation', 'promotion')),
  note        text,
  created_at  timestamptz not null default now()
);
alter table public.customer_kind_overrides enable row level security;
revoke all on public.customer_kind_overrides from anon, authenticated;

insert into public.customer_kind_overrides (customer_id, kind, note) values
  ('C000001265', 'donation', 'DONATIONS'),
  ('C000009677', 'donation', 'DONATIONS DTT'),
  ('C000009417', 'pickup',   'SHERYL CORNER PICK UP')
on conflict (customer_id) do nothing;

create or replace function public.dispatch_customer_kinds()
returns table (customer_id text, kind text)
language sql stable security definer set search_path = public as $$
  select o.customer_id::text, o.kind::text from customer_kind_overrides o
  union all
  select c.customer_id::text, 'promotion' from customers c
   where upper(coalesce(c.customer_class, '')) = 'PROMOTION'
     and not exists (select 1 from customer_kind_overrides o where o.customer_id = c.customer_id);
$$;
revoke all on function public.dispatch_customer_kinds() from public, anon;
grant execute on function public.dispatch_customer_kinds() to authenticated;
