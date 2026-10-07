-- One Acumatica job at a time per target (test / sandbox26 / live).
--
-- Acumatica limits concurrent API requests (6 on production, 1 on the 2026R1
-- sandbox) and requests per minute (150 / 50). Edge function runs can overlap
-- (two clerks, a sync and a writeback), so before signing in each run takes
-- the target's lease here, renews it as it goes, and drops it when done. A run
-- that dies leaves a lease that expires on its own.
--
-- Used only by edge functions with the service role.

create table public.acu_leases (
  target     text primary key,
  holder     uuid not null,
  job        text,
  taken_at   timestamptz not null default now(),
  expires_at timestamptz not null
);
alter table public.acu_leases enable row level security;
revoke all on public.acu_leases from anon, authenticated;

-- Take or renew. True if p_holder now holds the lease.
create function public.acu_lease_take(p_target text, p_holder uuid, p_job text, p_seconds int default 90)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  insert into acu_leases (target, holder, job, expires_at)
  values (p_target, p_holder, p_job, now() + make_interval(secs => p_seconds))
  on conflict (target) do update
    set holder = excluded.holder, job = excluded.job, expires_at = excluded.expires_at,
        taken_at = case when acu_leases.holder = excluded.holder then acu_leases.taken_at else now() end
    where acu_leases.holder = excluded.holder or acu_leases.expires_at < now();
  return exists (select 1 from acu_leases where target = p_target and holder = p_holder);
end $$;

create function public.acu_lease_drop(p_target text, p_holder uuid)
returns void language sql security definer set search_path = public as $$
  delete from acu_leases where target = p_target and holder = p_holder;
$$;

revoke execute on function public.acu_lease_take(text, uuid, text, int) from public, anon, authenticated;
revoke execute on function public.acu_lease_drop(text, uuid) from public, anon, authenticated;
grant execute on function public.acu_lease_take(text, uuid, text, int) to service_role;
grant execute on function public.acu_lease_drop(text, uuid) to service_role;
