-- Go-live prep (2026-10-07).
--
-- 1. Picker and checker roles beside batcher (Internal Logistics Coordinator)
--    and clerk (Trucker Liaison).
-- 2. A cron token in Vault, so the scheduled live line-item sync can call
--    dispatch-acu without a user session. The function checks the token with
--    dispatch_cron_ok(); nothing outside the service role can read it.
-- 3. dispatch_set_values(): bulk-set shipment_value on public.shipments from the
--    live line sync (the production SO-Shipment GI has no line data).

alter table public.dispatch_roles drop constraint dispatch_roles_role_check;
alter table public.dispatch_roles add constraint dispatch_roles_role_check
  check (role in ('batcher', 'clerk', 'picker', 'checker'));

select vault.create_secret(encode(gen_random_bytes(32), 'hex'), 'dispatch_cron_token',
                           'Bearer for cron -> dispatch-acu (sync_live_lines)')
where not exists (select 1 from vault.secrets where name = 'dispatch_cron_token');

create function public.dispatch_cron_ok(p_token text) returns boolean
language sql stable security definer set search_path = public, vault as $$
  select exists (select 1 from vault.decrypted_secrets
                  where name = 'dispatch_cron_token' and decrypted_secret = p_token and p_token <> '');
$$;
revoke all on function public.dispatch_cron_ok(text) from public, anon, authenticated;

-- [{shipment_nbr, value}] -> shipments.shipment_value
create function public.dispatch_set_values(p_rows jsonb) returns int
language sql security definer set search_path = public as $$
  with r as (select x->>'shipment_nbr' nbr, (x->>'value')::numeric val from jsonb_array_elements(p_rows) x),
       u as (update shipments s set shipment_value = r.val from r where s.shipment_nbr = r.nbr returning 1)
  select count(*)::int from u;
$$;
revoke all on function public.dispatch_set_values(jsonb) from public, anon, authenticated;
