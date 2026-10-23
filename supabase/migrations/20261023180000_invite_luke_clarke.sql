-- Luke Clarke: supervisor + manager (Joel, 2026-10-23). He hasn't signed in yet, so these are
-- invites; the roles are granted when his account is first created (dispatch_apply_invites).
insert into public.dispatch_role_invites (email, role) values
  ('luke.clarke@dflimporters.com', 'supervisor'),
  ('luke.clarke@dflimporters.com', 'manager')
on conflict do nothing;

insert into public.dispatch_roles (user_id, role)
select u.id, i.role from public.dispatch_role_invites i
  join auth.users u on lower(u.email) = i.email
 where i.email = 'luke.clarke@dflimporters.com'
on conflict do nothing;
