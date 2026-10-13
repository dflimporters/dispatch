-- Dispatch lockdown (audit 2026-10-12). DRAFT: review before applying.
--
-- 1. shipments, ship_via_codes, truck_types were readable by ANY signed-in user
--    (policy "true"). This project also hosts the sales / merchandiser portal,
--    so those users could read live shipment data, customer names, values and
--    trucker details. Reads now need a dispatch role, like shipments_test.
--    Checked: no view, no non-dispatch function and no other policy in this
--    database references these three tables. The sales portal's own front end
--    is a separate repo; confirm it doesn't read them before applying.
--
-- 2. Same tables: anon / authenticated also held INSERT/UPDATE/DELETE/TRUNCATE
--    grants, held back only by RLS having no write policy. Revoked outright.
--    Sync jobs and edge functions use the service role and are unaffected.
--
-- 3. sync-so-ordered-items (feeds so_ordered_items, which transfers, pick areas
--    and the dashboard read) has verify_jwt off and its cron call carries no
--    credentials, so anyone with the URL can trigger Acumatica pulls. The cron
--    job now sends the Vault dispatch_cron_token. The function must then check
--    it (supabase/functions/sync-so-ordered-items/index.ts, deploy it AFTER this
--    migration, or the sync stops).
--
-- Rollback is at the bottom.

-- ------------------------------------------------------------------
-- 1. Reads need a dispatch role
-- ------------------------------------------------------------------
drop policy if exists shipments_read_authenticated    on public.shipments;
drop policy if exists truck_types_read_authenticated  on public.truck_types;
drop policy if exists ship_via_codes_read             on public.ship_via_codes;

create policy shipments_read    on public.shipments
  for select to authenticated using (public.dispatch_has_role());
create policy truck_types_read  on public.truck_types
  for select to authenticated using (public.dispatch_has_role());
create policy ship_via_codes_read on public.ship_via_codes
  for select to authenticated using (public.dispatch_has_role());

-- ------------------------------------------------------------------
-- 2. No direct writes, no anonymous access at the grant level
-- ------------------------------------------------------------------
revoke all on public.shipments, public.truck_types, public.ship_via_codes from anon;
revoke insert, update, delete, truncate on public.shipments, public.truck_types, public.ship_via_codes from authenticated;

-- ------------------------------------------------------------------
-- 3. Authenticate the so_ordered_items sync cron call
-- ------------------------------------------------------------------
-- cron.schedule with an existing job name replaces that job. Same schedule,
-- timeout and (empty) body as the previous command; only the header is new.
select cron.schedule('nightly-sync-so-ordered-items', '4-59/5 10-23,0-1 * * *', $cron$
  select net.http_post(
    url := 'https://hzagwndglwhcepsirafi.supabase.co/functions/v1/sync-so-ordered-items',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'dispatch_cron_token')),
    timeout_milliseconds := 120000)
$cron$);

-- ------------------------------------------------------------------
-- Rollback (run by hand if the sales portal turns out to need these reads)
-- ------------------------------------------------------------------
-- drop policy shipments_read on public.shipments;
-- drop policy truck_types_read on public.truck_types;
-- drop policy ship_via_codes_read on public.ship_via_codes;
-- create policy shipments_read_authenticated   on public.shipments   for select to authenticated using (true);
-- create policy truck_types_read_authenticated on public.truck_types for select to authenticated using (true);
-- create policy ship_via_codes_read            on public.ship_via_codes for select to authenticated using (true);
-- (cron: re-create the job without the Authorization header)
