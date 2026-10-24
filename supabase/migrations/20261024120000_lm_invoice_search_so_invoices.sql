-- lm_invoice_search: read so_invoices, not invoices (Joel, 2026-10-24).
-- invoices.ship_via is empty for most recent invoices (4,222 of 16,182 Open rows have one), so the
-- search could not group an invoice's run by Ship Via. so_invoices carries the Ship Via on every
-- row (sync-so-invoices backfills it) and has the same columns the search uses.
-- Only the table name changes; the build function is untouched.

create or replace function public.lm_invoice_search(p_nbr text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  n    text := btrim(coalesce(p_nbr, ''));
  ord  text[];
  via  text;
  d    date;
  invs jsonb;
  ships jsonb;
begin
  if auth.uid() is null or not lm_staff() then
    raise exception 'Your account doesn''t have a dispatch role' using errcode = '42501';
  end if;
  if n = '' then raise exception 'Type an invoice or shipment number'; end if;

  select array_agg(distinct i.order_number), min(i.ship_via), min(i.invoice_date)
    into ord, via, d
    from so_invoices i where i.reference_number = n;
  if ord is null then
    select array_agg(distinct i.order_number), min(i.ship_via), min(i.invoice_date)
      into ord, via, d
      from so_invoices i
     where i.order_number in (select s.order_nbr from shipments s where s.shipment_nbr = n);
  end if;
  if ord is null then
    return jsonb_build_object('found', false, 'nbr', n);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'reference_number', i.reference_number, 'order_number', i.order_number,
           'customer_name', i.customer_name, 'status', i.status, 'amount', i.invoice_amount,
           'typed', i.order_number = any (ord))
         order by i.customer_name, i.reference_number), '[]'::jsonb)
    into invs
    from so_invoices i
   where i.ship_via = via and i.invoice_date = d
     and (i.status = 'Open' or i.order_number = any (ord));

  select coalesce(jsonb_agg(row_to_json(x)::jsonb order by x.customer_name, x.shipment_nbr), '[]'::jsonb)
    into ships
    from (
      select s.shipment_nbr, s.order_nbr, s.customer_id, s.customer_name, s.status,
             (select coalesce(sum(sl.shipped_qty), 0) from shipment_lines sl
               where sl.env = 'live' and sl.shipment_nbr = s.shipment_nbr) as units,
             (select jsonb_agg(distinct i.reference_number) from so_invoices i
               where i.order_number = s.order_nbr and i.ship_via = via and i.invoice_date = d) as invoice_nbrs,
             ex.load_nbr as on_load,
             case
               when s.status <> 'Completed' then 'Still ' || s.status || ' in Acumatica'
               when not exists (select 1 from shipment_lines sl
                                 where sl.env = 'live' and sl.shipment_nbr = s.shipment_nbr and sl.shipped_qty > 0)
                    then 'Item lines not synced from Acumatica yet'
               when ex.load_nbr is not null and not ex.reusable then 'Already on ' || ex.load_nbr
             end as blocked
        from shipments s
        left join lateral (
          select l.load_nbr, (l.source = 'acumatica' and l.check_status is null) as reusable
            from load_shipments ls join loads l on l.id = ls.load_id
           where ls.env = 'live' and ls.shipment_nbr = s.shipment_nbr limit 1) ex on true
       where s.order_nbr in (select (j ->> 'order_number') from jsonb_array_elements(invs) j)
         and s.ship_via = via and s.operation = 'Issue' and coalesce(s.order_type, '') <> 'RC'
    ) x;

  return jsonb_build_object('found', true, 'nbr', n, 'ship_via', via,
    'trucker', (select description from ship_via_codes where ship_via = via),
    'invoice_date', d, 'invoices', invs, 'shipments', ships);
end $$;
