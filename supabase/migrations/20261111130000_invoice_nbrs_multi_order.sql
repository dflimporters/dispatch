-- _lm_invoice_nbrs fixes (Brooklyn Clock Tower, L-1111-01): a shipment can carry several sales orders
-- ("209982, 210187" in shipments.order_nbr), and the invoice may have no order_number in so_invoices.
-- 1) match any of the comma-separated orders; 2) if nothing matches, use the invoice number(s) printed against the shipment.
create or replace function public._lm_invoice_nbrs(p_shipment text, p_load_date date) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select string_agg(distinct i.reference_number, ', ')
       from so_invoices i
      where i.order_number = any (select btrim(o) from shipments s, unnest(string_to_array(s.order_nbr, ',')) o
                                   where s.shipment_nbr = p_shipment)
        and (i.invoice_date = p_load_date
             or not exists (select 1 from so_invoices j
                             where j.order_number = i.order_number and j.invoice_date = p_load_date))),
    (select string_agg(distinct p.invoice_nbr, ', ') from invoice_prints p
      where p.shipment_nbr = p_shipment and p.invoice_nbr is not null));
$$;
revoke all on function public._lm_invoice_nbrs(text, date) from public, anon, authenticated;
