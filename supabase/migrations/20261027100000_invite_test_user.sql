-- test@dflimporters.com: every dispatch role, so it can open the whole portal (Joel, 2026-10-27).
-- Invites are applied when the account is first created (dispatch_apply_invites); if it already
-- exists the roles are granted below.
insert into public.dispatch_role_invites (email, role) values
  ('test@dflimporters.com', 'batcher'),
  ('test@dflimporters.com', 'clerk'),
  ('test@dflimporters.com', 'picker'),
  ('test@dflimporters.com', 'checker'),
  ('test@dflimporters.com', 'supervisor'),
  ('test@dflimporters.com', 'manager')
on conflict do nothing;

insert into public.dispatch_roles (user_id, role)
select u.id, i.role from public.dispatch_role_invites i
  join auth.users u on lower(u.email) = i.email
 where i.email = 'test@dflimporters.com'
on conflict do nothing;
