-- Pre-provisioned dispatch roles, keyed by email, for people who have not signed
-- in yet. When an account is first created in auth.users, any invite rows for its
-- email are turned into dispatch_roles. Add a row here instead of waiting for the
-- person to sign in once. Separate from handle_new_user so the portal's own
-- provisioning is untouched.

create table if not exists public.dispatch_role_invites (
  email      text not null,
  role       text not null check (role in ('batcher', 'clerk', 'picker', 'checker', 'supervisor', 'manager')),
  created_at timestamptz not null default now(),
  primary key (email, role),
  check (email = lower(email))
);
alter table public.dispatch_role_invites enable row level security;
revoke all on public.dispatch_role_invites from anon, authenticated;

create or replace function public.dispatch_apply_invites() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into dispatch_roles (user_id, role)
  select new.id, i.role from dispatch_role_invites i where i.email = lower(new.email)
  on conflict do nothing;
  return new;
end $$;
revoke all on function public.dispatch_apply_invites() from public, anon, authenticated;

drop trigger if exists dispatch_apply_invites on auth.users;
create trigger dispatch_apply_invites after insert on auth.users
  for each row execute function public.dispatch_apply_invites();

-- Warehouse tablets (2026-10-12).
--   warehousetab  -> Checker screen only
--   warehousetab2 -> Picking screen only (the picker role sees every area)
insert into public.dispatch_role_invites (email, role) values
  ('warehousetab@dflimporters.com',  'checker'),
  ('warehousetab2@dflimporters.com', 'picker')
on conflict do nothing;

-- If either account somehow already exists, grant now as well.
insert into public.dispatch_roles (user_id, role)
select u.id, i.role from public.dispatch_role_invites i
  join auth.users u on lower(u.email) = i.email
on conflict do nothing;
