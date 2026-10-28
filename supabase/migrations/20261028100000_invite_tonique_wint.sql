-- Tonique Wint: batcher + clerk, same as Robert Johnson (Joel, 2026-10-28). She hasn't signed in
-- yet, so these are invites; the roles are granted when her account is first created
-- (dispatch_apply_invites).
insert into public.dispatch_role_invites (email, role) values
  ('tonique.wint@dflimporters.com', 'batcher'),
  ('tonique.wint@dflimporters.com', 'clerk')
on conflict do nothing;

insert into public.dispatch_roles (user_id, role)
select u.id, i.role from public.dispatch_role_invites i
  join auth.users u on lower(u.email) = i.email
 where i.email = 'tonique.wint@dflimporters.com'
on conflict do nothing;
