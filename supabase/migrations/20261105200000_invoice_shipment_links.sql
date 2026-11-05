-- 2026-11-05. Match an invoice to its shipment directly, not through the sales order.
--
-- Problem: the invoicing page found a shipment's invoice by sales-order number (so_invoices.order_number).
-- A shipment that carries lines from two orders (a substitution on a new SO: shipment 283531 = SO 209623 +
-- 209696) is billed on one invoice (1060285) whose header OrderNbr is blank, so it showed "pending" forever.
--
-- Fix: Acumatica puts the ShipmentNbr (and OrderNbr) on every invoice line. sync-invoice-print now stores
-- one row per (invoice, shipment, order) here, and the page asks for the invoice by shipment.
--
-- Also: shipment_lines.line_value / shipments.shipment_value were left at the pre-check quantity when the
-- checker lowered a line, so the page showed more than the invoice. They now follow shipped_qty.

-- 1. The link table -------------------------------------------------------
create table public.invoice_shipments (
  reference_number text not null,
  shipment_nbr     text not null,
  order_nbr        text not null default '',
  synced_at        timestamptz not null default now(),
  primary key (reference_number, shipment_nbr, order_nbr)
);
create index invoice_shipments_shipment_idx on public.invoice_shipments (shipment_nbr);
create index invoice_shipments_order_idx on public.invoice_shipments (order_nbr);
alter table public.invoice_shipments enable row level security;   -- no policy: read through the function below

-- 2. Invoice for each shipment ---------------------------------------------
-- p_items: [{ "shipment_nbr": "283531", "order_nbr": "209623, 209696" }, ...]  (order_nbr as on shipments).
-- 1) The link table wins (exact shipment match; newest non-cancelled invoice if there are several).
-- 2) Only when the shipment has no link yet: an invoice of one of its orders (any of them), and only if it is
--    unambiguous (exactly one such invoice) and that invoice has no links recorded for another shipment, so an
--    order billed in several shipments can never hand one shipment another's invoice.
create function public.invoice_print_for_shipments(p_items jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not (dispatch_has_role('supervisor') or dispatch_has_role('manager')) then
    raise exception 'Only a supervisor can print invoices' using errcode = '42501';
  end if;
  return coalesce((
    with want as (
      select x->>'shipment_nbr' as shipment_nbr,
             array(select btrim(o) from unnest(string_to_array(coalesce(x->>'order_nbr', ''), ',')) o where btrim(o) <> '') as orders
        from jsonb_array_elements(p_items) x
    ), linked as (
      select distinct on (w.shipment_nbr) w.shipment_nbr, l.reference_number
        from want w
        join invoice_shipments l on l.shipment_nbr = w.shipment_nbr
        left join so_invoices i on i.reference_number = l.reference_number
       where coalesce(i.status, '') not in ('Canceled', 'Cancelled', 'Voided')
       order by w.shipment_nbr, i.invoice_date desc nulls last, l.reference_number desc
    ), fallback as (
      select w.shipment_nbr, min(i.reference_number) as reference_number
        from want w
        join so_invoices i on i.order_number = any (w.orders)
       where w.shipment_nbr not in (select shipment_nbr from linked)
         and coalesce(i.status, '') not in ('Canceled', 'Cancelled', 'Voided')
         and not exists (select 1 from invoice_shipments l where l.reference_number = i.reference_number)
       group by w.shipment_nbr
      having count(distinct i.reference_number) = 1
    ), pick as (
      select * from linked union all select * from fallback
    )
    select jsonb_agg(jsonb_build_object(
             'shipment_nbr', p.shipment_nbr, 'reference_number', p.reference_number,
             'order_number', i.order_number, 'customer_id', i.customer_id, 'customer_name', i.customer_name,
             'status', i.status, 'invoice_date', i.invoice_date, 'invoice_amount', i.invoice_amount,
             'ship_via', i.ship_via, 'ship_via_description', i.ship_via_description))
      from pick p left join so_invoices i on i.reference_number = p.reference_number
  ), '[]'::jsonb);
end $$;
revoke all on function public.invoice_print_for_shipments(jsonb) from public, anon;
grant execute on function public.invoice_print_for_shipments(jsonb) to authenticated;

-- 3. Value follows the shipped quantity ------------------------------------
create or replace function public.shipment_lines_value_follows_qty() returns trigger
language plpgsql as $$
declare v numeric;
begin
  if tg_op = 'UPDATE' and new.shipped_qty is distinct from old.shipped_qty and new.unit_price is not null then
    new.line_value := round(coalesce(new.shipped_qty, 0) * new.unit_price, 2);
  end if;
  return new;
end $$;
drop trigger if exists shipment_lines_value_follows_qty on public.shipment_lines;
create trigger shipment_lines_value_follows_qty before update on public.shipment_lines
  for each row execute function public.shipment_lines_value_follows_qty();

create or replace function public.shipment_value_after_qty() returns trigger
language plpgsql as $$
declare v numeric;
begin
  if new.shipped_qty is not distinct from old.shipped_qty then return null; end if;
  select round(sum(coalesce(line_value, 0)), 2) into v from shipment_lines where env = new.env and shipment_nbr = new.shipment_nbr;
  if coalesce(v, 0) > 0 then
    if new.env = 'live' then update shipments set shipment_value = v where shipment_nbr = new.shipment_nbr;
    else update shipments_test set shipment_value = v where shipment_nbr = new.shipment_nbr; end if;
  end if;
  return null;
end $$;
drop trigger if exists shipment_value_after_qty on public.shipment_lines;
create trigger shipment_value_after_qty after update of shipped_qty on public.shipment_lines
  for each row execute function public.shipment_value_after_qty();

-- Backfill: lines the checker already lowered, and the shipment totals they feed.
update public.shipment_lines
   set line_value = round(coalesce(shipped_qty, 0) * unit_price, 2)
 where env = 'live' and unit_price is not null and line_value is distinct from round(coalesce(shipped_qty, 0) * unit_price, 2);

update public.shipments s set shipment_value = t.v
  from (select shipment_nbr, round(sum(coalesce(line_value, 0)), 2) v from shipment_lines where env = 'live' group by 1) t
 where s.shipment_nbr = t.shipment_nbr and t.v > 0 and s.shipment_value is distinct from t.v
   and s.status in ('Confirmed', 'Invoiced', 'Completed');

-- Rollback:
--   drop trigger shipment_value_after_qty on public.shipment_lines;  drop function public.shipment_value_after_qty();
--   drop trigger shipment_lines_value_follows_qty on public.shipment_lines;  drop function public.shipment_lines_value_follows_qty();
--   drop function public.invoice_print_for_shipments(jsonb);  drop table public.invoice_shipments;
