-- Invoice printing log (Joel, 2026-10-27).
-- Every print of an invoice from the Invoicing panel is recorded: who, when, which shipment / invoice.
-- Rule (pick-check-invoice-design): first print is free; a reprint needs a reason, is watermarked, and is logged.
-- The server decides first print vs reprint (counts earlier prints), so the page can't skip the watermark or the reason.
-- Recorded when the print dialog is opened; the browser can't tell whether paper actually came out.
-- Also written to audit_log ('invoice.print' / 'invoice.reprint') so the admin page shows it.
--
-- Rollback at the bottom.

create table public.invoice_prints (
  id            bigint generated always as identity primary key,
  env           text not null check (env in ('live', 'test')),
  shipment_nbr  text not null,
  invoice_nbr   text,
  load_id       bigint,
  load_nbr      text,
  print_no      int  not null,              -- 1 = original, 2+ = reprint
  reprint       boolean not null,
  reason        text,                        -- required when reprint
  method        text not null default 'browser',
  printed_by    uuid default auth.uid(),
  printed_name  text,
  printed_at    timestamptz not null default now()
);
create index invoice_prints_ship on public.invoice_prints (env, shipment_nbr, printed_at desc);
create index invoice_prints_load on public.invoice_prints (load_id, printed_at desc) where load_id is not null;
alter table public.invoice_prints enable row level security;
create policy invoice_prints_read on public.invoice_prints for select to authenticated
  using (public.dispatch_has_role('supervisor') or public.dispatch_has_role('manager') or public._admin_ok());
revoke all on public.invoice_prints from anon;
revoke insert, update, delete, truncate on public.invoice_prints from authenticated;

-- p_items: [{shipment_nbr, invoice_nbr}]. Returns [{shipment_nbr, invoice_nbr, print_no, reprint}].
create function public.invoice_print_record(p_env text, p_items jsonb, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  it     jsonb;
  nbr    text;
  inv    text;
  n      int;
  ld     record;
  why    text := nullif(btrim(coalesce(p_reason, '')), '');
  out    jsonb := '[]'::jsonb;
  lock_k text;
begin
  if auth.uid() is null or not dispatch_has_role('supervisor') then
    raise exception 'Only a supervisor can print invoices' using errcode = '42501';
  end if;
  if p_env not in ('live', 'test') then raise exception 'Bad environment'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Nothing to print'; end if;
  if jsonb_array_length(p_items) > 200 then raise exception 'Print at most 200 invoices at a time'; end if;

  -- Work out all print numbers first so a missing reason rejects the whole batch.
  for it in select * from jsonb_array_elements(p_items) loop
    nbr := btrim(it ->> 'shipment_nbr');
    if nbr is null or nbr = '' then raise exception 'Shipment number missing'; end if;
    select count(*) into n from invoice_prints where env = p_env and shipment_nbr = nbr;
    if n > 0 and why is null then
      raise exception 'Reprints need a reason (% was printed before)', nbr;
    end if;
  end loop;

  for it in select * from jsonb_array_elements(p_items) loop
    nbr := btrim(it ->> 'shipment_nbr');
    inv := nullif(btrim(coalesce(it ->> 'invoice_nbr', '')), '');
    lock_k := 'invprint:' || p_env || ':' || nbr;
    perform pg_advisory_xact_lock(hashtext(lock_k));
    select count(*) + 1 into n from invoice_prints where env = p_env and shipment_nbr = nbr;
    select l.id, l.load_nbr into ld from load_shipments ls join loads l on l.id = ls.load_id
     where ls.env = p_env and ls.shipment_nbr = nbr order by l.id desc limit 1;
    insert into invoice_prints (env, shipment_nbr, invoice_nbr, load_id, load_nbr, print_no, reprint, reason, printed_name)
    values (p_env, nbr, inv, ld.id, ld.load_nbr, n, n > 1, case when n > 1 then why end, dispatch_actor_name());
    perform _audit(case when n > 1 then 'invoice.reprint' else 'invoice.print' end, 'shipment', nbr,
      case when n > 1 then 'Reprint #' || n || ': ' || why else 'Printed' end || coalesce(' (invoice ' || inv || ')', ''),
      null, jsonb_build_object('invoice_nbr', inv, 'print_no', n), p_env, ld.id, ld.load_nbr, nbr);
    out := out || jsonb_build_object('shipment_nbr', nbr, 'invoice_nbr', inv, 'print_no', n, 'reprint', n > 1);
  end loop;
  return out;
end $$;
revoke all on function public.invoice_print_record(text, jsonb, text) from public, anon;
grant execute on function public.invoice_print_record(text, jsonb, text) to authenticated;

-- Invoice headers (so_invoices, synced from Acumatica) for these sales orders, newest first.
-- so_invoices has no policy for the panel, so it is read here, supervisor / manager only.
create function public.invoice_print_headers(p_orders text[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not (dispatch_has_role('supervisor') or dispatch_has_role('manager')) then
    raise exception 'Only a supervisor can print invoices' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.invoice_date desc, x.reference_number desc) from (
      select i.reference_number, i.order_number, i.customer_id, i.customer_name, i.status, i.invoice_date,
             i.invoice_amount, i.ship_via, i.ship_via_description
        from so_invoices i
       where i.order_number = any (p_orders) and coalesce(i.status, '') not in ('Canceled', 'Cancelled', 'Voided')
       limit 1000) x), '[]'::jsonb);
end $$;
revoke all on function public.invoice_print_headers(text[]) from public, anon;
grant execute on function public.invoice_print_headers(text[]) to authenticated;

-- Rollback:
--   drop function public.invoice_print_headers(text[]);
--   drop function public.invoice_print_record(text, jsonb, text);
--   drop table public.invoice_prints;
