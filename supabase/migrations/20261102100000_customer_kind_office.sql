-- DFL Office expense orders get their own customer kind, so the Sales Orders tab can show them apart
-- from normal deliveries and ship them straight to invoice (like pickup, donation and promotion).
alter table public.customer_kind_overrides drop constraint if exists customer_kind_overrides_kind_check;
alter table public.customer_kind_overrides
  add constraint customer_kind_overrides_kind_check check (kind in ('pickup', 'donation', 'promotion', 'office'));

insert into public.customer_kind_overrides (customer_id, kind, note) values
  ('C000006724', 'office', 'DFL Office Expense')
on conflict (customer_id) do update set kind = excluded.kind, note = excluded.note;
