-- New load numbers ignore high hand-set numbers and never collide (Joel, 2026-11-10).
--
-- The team renumbers some loads to 97/98/99 (ACU auto-loads) by hand. loads_number() took "highest
-- used + 1", so every new load got L-DDMM-100, and a second create while one still sat at 100
-- (not yet renumbered) failed with: duplicate key value violates unique constraint "loads_nbr_unique".
--
-- Now: the next number is the highest below 90, plus 1, then stepped forward past anything already
-- taken (including suffixed ones like 05ADD, which share the digits). Numbers 90+ are left for
-- hand-set / ACU loads.

create or replace function public.loads_number() returns trigger
language plpgsql set search_path = public as $$
declare
  work_day date := (now() at time zone 'America/Jamaica')::date;
  prefix   text := 'L-' || to_char((now() at time zone 'America/Jamaica')::date, 'DDMM') || '-';
  n int;
begin
  if tg_op = 'INSERT' then
    perform pg_advisory_xact_lock(hashtext('loads:' || new.env || work_day::text));
    select coalesce(max(substring(load_nbr from length(prefix) + 1 for 2)::int), 0) + 1 into n
      from public.loads
     where env = new.env
       and load_nbr ~ ('^' || prefix || '[0-9]{2}[A-Z]{0,3}$')
       and substring(load_nbr from length(prefix) + 1 for 2)::int < 90
       and created_at > now() - interval '180 days';
    while exists (select 1 from public.loads where env = new.env and load_nbr = prefix || lpad(n::text, 2, '0')) loop
      n := n + 1;
    end loop;
    new.seq := n;
    new.load_nbr := prefix || lpad(n::text, 2, '0');
  end if;
  new.updated_at := now();
  return new;
end $$;

-- Load 510 was renamed to 10 by hand but kept seq 100.
update public.loads set seq = 10 where env = 'live' and load_nbr = 'L-1011-10' and seq = 100;
