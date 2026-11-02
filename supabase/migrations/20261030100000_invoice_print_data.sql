-- Invoice print data (Joel, 2026-10-30).
-- Full invoice content (header, bill/ship blocks, lines with UOM, per-line tax category, notes) read from the
-- Acumatica Generic Inquiry DFLInvoicePrint by the sync-invoice-print edge function (see docs/invoice-print-gi.md).
-- The print layout reads it through invoice_print_fetch(), supervisor / manager only.
--
-- Tables are written by the service role only (the edge function). RLS is on with no policies and direct
-- table access is revoked, so the functions below are the only way in.
--
-- Rollback at the bottom.

create table public.invoice_print_headers (
  ref            text primary key,           -- Acumatica invoice reference number
  doc_type       text,
  doc_date       date,
  due_date       date,
  status         text,
  customer_id    text,
  customer_name  text,
  currency       text,
  terms          text,                        -- terms description (falls back to the terms id)
  salesperson    text,
  so_number      text,
  shipment_nbr   text,
  customer_po    text,
  customer_ref   text,
  ship_via       text,
  bill           jsonb not null default '{"name": null, "lines": []}'::jsonb,   -- {name, lines[]}
  ship           jsonb not null default '{"name": null, "lines": []}'::jsonb,   -- {name, lines[]}
  sales_total    numeric,
  discount_total numeric,
  tax_total      numeric,
  total          numeric,
  last_modified  timestamptz,                 -- Acumatica LastModifiedDateTime; the sync picks up newer ones
  synced_at      timestamptz not null default now()
);
create index invoice_print_headers_date on public.invoice_print_headers (doc_date desc);
create index invoice_print_headers_modified on public.invoice_print_headers (last_modified desc);
create index invoice_print_headers_ship on public.invoice_print_headers (shipment_nbr) where shipment_nbr is not null;

create table public.invoice_print_lines (
  ref          text not null,
  line_nbr     int  not null,
  inventory_cd text,
  descr        text,
  qty          numeric,
  uom          text,
  unit_price   numeric,
  tax_cat      text,
  amount       numeric,
  discount     numeric,
  note         text,
  primary key (ref, line_nbr)
);

alter table public.invoice_print_headers enable row level security;
alter table public.invoice_print_lines   enable row level security;
revoke all on public.invoice_print_headers from anon, authenticated;
revoke all on public.invoice_print_lines   from anon, authenticated;

-- Invoices in the contract shape (docs/invoice-print-gi.md section 3), lines ordered by n.
-- Refs not synced yet are simply absent from the result; see invoice_print_missing().
create function public.invoice_print_fetch(p_refs text[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not (dispatch_has_role('supervisor') or dispatch_has_role('manager')) then
    raise exception 'Only a supervisor can print invoices' using errcode = '42501';
  end if;
  if p_refs is null or coalesce(array_length(p_refs, 1), 0) = 0 then raise exception 'Nothing to fetch'; end if;
  if array_length(p_refs, 1) > 200 then raise exception 'Fetch at most 200 invoices at a time'; end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'ref',            h.ref,
        'doc_type',       h.doc_type,
        'date',           to_char(h.doc_date, 'YYYY-MM-DD'),
        'due_date',       to_char(h.due_date, 'YYYY-MM-DD'),
        'status',         h.status,
        'customer_id',    h.customer_id,
        'currency',       h.currency,
        'terms',          h.terms,
        'salesperson',    h.salesperson,
        'so_number',      h.so_number,
        'shipment_nbr',   h.shipment_nbr,
        'customer_po',    h.customer_po,
        'customer_ref',   h.customer_ref,
        'ship_via',       h.ship_via,
        'bill',           h.bill,
        'ship',           h.ship,
        'sales_total',    h.sales_total,
        'discount_total', h.discount_total,
        'tax_total',      h.tax_total,
        'total',          h.total,
        'lines', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'n',          l.line_nbr,
              'item',       l.inventory_cd,
              'descr',      l.descr,
              'qty',        l.qty,
              'uom',        l.uom,
              'unit_price', l.unit_price,
              'tax_cat',    l.tax_cat,
              'amount',     l.amount,
              'discount',   l.discount,
              'note',       l.note
            ) order by l.line_nbr)
            from invoice_print_lines l where l.ref = h.ref
        ), '[]'::jsonb)
      ) order by h.ref)
    from invoice_print_headers h
   where h.ref = any (p_refs)
  ), '[]'::jsonb);
end $$;
revoke all on function public.invoice_print_fetch(text[]) from public, anon;
grant execute on function public.invoice_print_fetch(text[]) to authenticated;

-- Which of these refs have no synced invoice yet (the page then calls sync-invoice-print with {refs}).
create function public.invoice_print_missing(p_refs text[]) returns text[]
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not (dispatch_has_role('supervisor') or dispatch_has_role('manager')) then
    raise exception 'Only a supervisor can print invoices' using errcode = '42501';
  end if;
  if p_refs is null or coalesce(array_length(p_refs, 1), 0) = 0 then return '{}'::text[]; end if;
  if array_length(p_refs, 1) > 200 then raise exception 'Check at most 200 invoices at a time'; end if;

  return coalesce((
    select array_agg(r order by r)
      from (select distinct unnest(p_refs) as r) q
     where not exists (select 1 from invoice_print_headers h where h.ref = q.r)
  ), '{}'::text[]);
end $$;
revoke all on function public.invoice_print_missing(text[]) from public, anon;
grant execute on function public.invoice_print_missing(text[]) to authenticated;

-- Rollback:
--   drop function public.invoice_print_missing(text[]);
--   drop function public.invoice_print_fetch(text[]);
--   drop table public.invoice_print_lines;
--   drop table public.invoice_print_headers;
