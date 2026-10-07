-- Shipment value (shipped qty x order line price, JMD). Filled for TEST by
-- dispatch-acu sync_test from the shipment's lines + so_ordered_items; the
-- live sync doesn't fill it yet. Added to both so the two tables keep the same
-- shape (_dispatch_shipments unions them).
alter table public.shipments      add column if not exists shipment_value numeric;
alter table public.shipments_test add column if not exists shipment_value numeric;
comment on column public.shipments.shipment_value is 'Shipped qty x order line price (JMD). Not filled by sync-shipments yet.';
