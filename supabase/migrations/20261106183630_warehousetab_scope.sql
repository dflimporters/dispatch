-- warehousetab@ (the two checker tablets) sees only Picking, Checker and Load sheets (Joel, 2026-11-06).
-- It had batcher, clerk, manager and supervisor as well. Keep picker + checker; the Load sheets page
-- now also admits the checker role, and the load-sheet tables are readable by it.
delete from public.dispatch_roles r using auth.users u
 where r.user_id = u.id and lower(u.email) = 'warehousetab@dflimporters.com'
   and r.role in ('batcher', 'clerk', 'manager', 'supervisor');
delete from public.dispatch_role_invites
 where email = 'warehousetab@dflimporters.com' and role in ('batcher', 'clerk', 'manager', 'supervisor');
insert into public.dispatch_role_invites (email, role) values
  ('warehousetab@dflimporters.com', 'picker'), ('warehousetab@dflimporters.com', 'checker')
on conflict do nothing;

drop policy lm_loads_read on public.lm_loads;
create policy lm_loads_read on public.lm_loads for select to authenticated
  using (public.lm_staff() or public.dispatch_has_role('invoicer') or public.dispatch_has_role('checker'));
