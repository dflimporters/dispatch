-- Invoice -> shipment links pulled every minute, and "Mark printed" for loads printed from Acumatica
-- (Joel, 2026-11-05).
--
-- 1. Until now the links (invoice_shipments) were only pulled when an Invoicing page noticed a row with
--    no invoice number, at most once a minute per browser tab, so clerks often hit Print on a row still
--    showing 'pending'. This job pulls them in the background (links only: no lines, cheap). Same hours
--    as sync-invoices (05:00-20:00 Jamaica). The function accepts the Vault dispatch_cron_token for it.
-- 2. The portal only knows about prints made from the portal. A clerk who printed a load from Acumatica
--    marks it here so it drops off the Invoicing print list (it stays under 'Show printed').
--
-- Rollback at the bottom.

select cron.schedule('dispatch-invoice-links-1min', '* 10-23,0-1 * * *', $cron$
  select net.http_post(
    url := 'https://hzagwndglwhcepsirafi.supabase.co/functions/v1/sync-invoice-print',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'dispatch_cron_token')),
    body := '{"links": true, "days_back": 2}'::jsonb,
    timeout_milliseconds := 55000)
$cron$);

create table public.invoice_load_marks (
  env          text   not null check (env in ('live', 'test')),
  load_id      bigint not null,
  load_nbr     text,
  marked_by    uuid default auth.uid(),
  marked_name  text,
  marked_at    timestamptz not null default now(),
  primary key (env, load_id)
);
alter table public.invoice_load_marks enable row level security;
create policy invoice_load_marks_read on public.invoice_load_marks for select to authenticated
  using (public.dispatch_has_role('supervisor') or public.dispatch_has_role('manager') or public._admin_ok());
revoke all on public.invoice_load_marks from anon;
revoke insert, update, delete, truncate on public.invoice_load_marks from authenticated;

create function public.invoice_load_mark_printed(p_env text, p_load_id bigint, p_marked boolean default true) returns void
language plpgsql security definer set search_path = public as $$
declare ld record;
begin
  if auth.uid() is null or not dispatch_has_role('supervisor') then
    raise exception 'Only a supervisor can mark loads printed' using errcode = '42501';
  end if;
  if p_env not in ('live', 'test') then raise exception 'Bad environment'; end if;
  select id, load_nbr into ld from loads where id = p_load_id and env = p_env;
  if ld.id is null then raise exception 'Load not found'; end if;
  if p_marked then
    insert into invoice_load_marks (env, load_id, load_nbr, marked_name)
    values (p_env, ld.id, ld.load_nbr, dispatch_actor_name())
    on conflict (env, load_id) do nothing;
  else
    delete from invoice_load_marks where env = p_env and load_id = ld.id;
  end if;
  perform _audit(case when p_marked then 'invoice.load_marked_printed' else 'invoice.load_unmarked' end, 'load', ld.id::text,
    case when p_marked then 'Marked printed (printed outside the portal)' else 'Printed mark removed' end,
    null, null, p_env, ld.id, ld.load_nbr, null);
end $$;
revoke all on function public.invoice_load_mark_printed(text, bigint, boolean) from public, anon;
grant execute on function public.invoice_load_mark_printed(text, bigint, boolean) to authenticated;

-- Rollback:
--   select cron.unschedule('dispatch-invoice-links-1min');
--   drop function public.invoice_load_mark_printed(text, bigint, boolean);
--   drop table public.invoice_load_marks;
