-- Items on each shipment, for the expandable shipment rows on the dispatch
-- pages. env 'test' is filled by dispatch-acu sync_test from the TEST
-- tenant's Shipment Details; 'live' has no source yet (the production
-- SO-Shipment GI has no line data).
create table public.shipment_lines (
  env            text not null check (env in ('live', 'test')),
  shipment_nbr   text not null,
  line_nbr       int  not null,
  inventory_id   text,
  description    text,
  uom            text,
  ordered_qty    numeric,     -- on the order line
  shipped_qty    numeric,     -- on this shipment
  order_type     text,
  order_nbr      text,
  order_line_nbr int,
  location_id    text,
  unit_price     numeric,
  line_value     numeric,     -- shipped_qty x unit_price
  synced_at      timestamptz not null default now(),
  primary key (env, shipment_nbr, line_nbr)
);
alter table public.shipment_lines enable row level security;
create policy shipment_lines_read on public.shipment_lines for select to authenticated using (public.dispatch_has_role());
revoke insert, update, delete, truncate on public.shipment_lines from anon, authenticated;
revoke all on public.shipment_lines from anon;
comment on table public.shipment_lines is 'Shipment line items for the dispatch pages. test = from TEST tenant via dispatch-acu sync_test; live not filled yet.';
