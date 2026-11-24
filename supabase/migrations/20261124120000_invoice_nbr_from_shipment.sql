-- Check-off sheets: take the invoice number from the shipment it was prepared from, not from the sales order.
-- (L-2311-33, FU Cheng: order 210773 carries an old Open invoice 1061820 as well as the new 1062219. Until the new
-- one reached so_invoices the sheet fell back to "every invoice on the order" and printed the old number.)
--
-- 1) shipment_invoicing.invoice_nbr: the invoice Acumatica created when the shipment was prepared. The dispatch-acu
--    edge function fills it from the shipment -> invoice link Acumatica itself reports (invoiceRefsByShipment).
-- 2) Backfill from the "Invoice 1062219 released" / "Prepared; invoice 1062246 not released" text already in detail.
-- 3) _lm_invoice_nbrs: that number first; then what was printed against the shipment; the old match-by-order
--    only as a last resort (invoices created in Acumatica outside the portal have no recorded link).
-- Callers (sheets, load sheet, shipment_gone_guard) are unchanged: same name, same signature.

alter table public.shipment_invoicing add column if not exists invoice_nbr text;

update public.shipment_invoicing
   set invoice_nbr = (regexp_match(detail, '[Ii]nvoice ([0-9]+)'))[1]
 where invoice_nbr is null and detail ~ '[Ii]nvoice [0-9]+';

create or replace function public._lm_invoice_nbrs(p_shipment text, p_load_date date) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select si.invoice_nbr from shipment_invoicing si
      where si.env = 'live' and si.shipment_nbr = p_shipment and si.invoice_nbr is not null),
    (select string_agg(distinct p.invoice_nbr, ', ') from invoice_prints p
      where p.env = 'live' and p.shipment_nbr = p_shipment and p.invoice_nbr is not null),
    (select string_agg(distinct i.reference_number, ', ')
       from so_invoices i
      where i.order_number = any (select btrim(o) from shipments s, unnest(string_to_array(s.order_nbr, ',')) o
                                   where s.shipment_nbr = p_shipment)
        and (i.invoice_date = p_load_date
             or not exists (select 1 from so_invoices j
                             where j.order_number = i.order_number and j.invoice_date = p_load_date))));
$$;
revoke all on function public._lm_invoice_nbrs(text, date) from public, anon, authenticated;

-- Rollback: restore the previous function from 20261111130000_invoice_nbrs_multi_order.sql, then
-- alter table public.shipment_invoicing drop column invoice_nbr;
