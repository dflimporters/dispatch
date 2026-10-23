-- Audit log for "Create shipments" on the Sales Orders tab (dispatch-orders edge function).
-- One row per order per request. Coordinators can read it; only the function writes it.
create table public.dispatch_shipment_requests (
  id            bigint generated always as identity primary key,
  env           text not null check (env in ('live', 'test')),
  order_nbr     text not null,
  shipment_date date not null,
  state         text not null check (state in ('created', 'none', 'refused', 'failed', 'skipped')),
  shipment_nbrs text[] not null default '{}',
  detail        text,
  requested_by  text,
  requested_at  timestamptz not null default now()
);
create index dispatch_shipment_requests_order on public.dispatch_shipment_requests (env, order_nbr, requested_at desc);
alter table public.dispatch_shipment_requests enable row level security;
create policy dispatch_shipment_requests_read on public.dispatch_shipment_requests
  for select to authenticated using (public.dispatch_has_role('batcher'));
revoke all on public.dispatch_shipment_requests from anon;
revoke insert, update, delete, truncate on public.dispatch_shipment_requests from authenticated;
