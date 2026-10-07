-- Real SO orders copied into the Acumatica TEST tenant by dispatch-test-seed,
-- to give the batcher realistic volume. One row per source order. Service
-- role only (no policies): written and read by the edge function.
create table public.dispatch_test_orders (
  source_order_nbr text primary key,        -- live SO order it was copied from
  source_date      date not null,
  test_order_nbr   text,                    -- the new SO in TEST
  ship_date        date,
  status           text not null,           -- created, shipped, skipped, failed
  shipment_nbrs    text[],
  lines            jsonb,                   -- [{line, inventory_id, qty, unit_price}] as sent
  detail           text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
alter table public.dispatch_test_orders enable row level security;
revoke all on public.dispatch_test_orders from anon, authenticated;
comment on table public.dispatch_test_orders is 'TEST-tenant seed log for the dispatch portal (dispatch-test-seed). Not production data.';
