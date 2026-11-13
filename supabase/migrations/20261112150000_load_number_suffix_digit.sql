-- A second (third...) addition to the same load needs its own number (Joel, 2026-11-12): 20ADD was
-- taken, so a suffix may now end in one digit, e.g. 20ADD2. Typed form is up to 6 characters
-- (20ADD2); full form L-DDMM-NN[A-Z]{0,3}[0-9]? is accepted too. Digits-only numbers are unchanged.
-- Still unique per env.

create or replace function public.dispatch_set_load_nbr(p_id bigint, p_nbr text) returns void
language plpgsql security definer set search_path = public as $$
declare l loads; n loads; nbr text := upper(trim(coalesce(p_nbr, ''))); m text[];
begin
  perform _dispatch_require('batcher');
  select * into l from loads where id = p_id for update;
  if not found then raise exception 'Load not found (it may have been deleted)'; end if;
  if l.confirm_requested_at is not null or l.check_status in ('confirming', 'confirmed', 'partial') then
    raise exception '% has been confirmed in Acumatica by the invoicer, so its number can''t be changed here', l.load_nbr;
  end if;
  -- Just the number, optionally with letters and one trailing digit (5, 05, 99, 05ADD, 05ADD2; max 6
  -- characters): keep the load's own L-DDMM- and pad the digits to two. A load still on an old-format
  -- number (L-MMDD-AM-NN) gets today's DDMM (Jamaica time).
  m := regexp_match(nbr, '^([0-9]{1,4})([A-Z]{0,3}[0-9]?)$');
  if m is not null and length(nbr) <= 6 then
    nbr := coalesce(case when l.load_nbr ~ '^L-[0-9]{4}-[0-9]+' then substr(l.load_nbr, 1, 7) end,
                    'L-' || to_char((now() at time zone 'America/Jamaica')::date, 'DDMM') || '-')
           || lpad(m[1], 2, '0') || m[2];
  elsif nbr !~ '^L-[0-9]{4}-[0-9]{2,}[A-Z]{0,3}[0-9]?$' then
    raise exception 'Enter the load number, e.g. 5, 05ADD or 05ADD2 (or the full L-0611-05)';
  end if;
  if nbr = l.load_nbr then return; end if;
  if exists (select 1 from loads where env = l.env and load_nbr = nbr and id <> l.id) then
    raise exception '% is already used by another load', nbr;
  end if;
  update loads set load_nbr = nbr, seq = substring(nbr from '^L-[0-9]{4}-([0-9]+)')::int
   where id = p_id returning * into n;
  perform _dispatch_log(n, 'edit', 'Load number changed from ' || l.load_nbr || ' to ' || n.load_nbr,
                        jsonb_build_object('old_nbr', l.load_nbr, 'new_nbr', n.load_nbr));
end $$;

-- Uniqueness covers the digit-ended suffixes too (the old loads_nbr_unique_sfx stays; this one is a
-- superset for suffixed numbers ending in a digit).
create unique index if not exists loads_nbr_unique_sfx_digit on public.loads (env, load_nbr)
  where load_nbr ~ '^L-[0-9]{4}-[0-9]+[A-Z]{1,3}[0-9]$';

-- Auto-numbering counts suffixed numbers (incl. a trailing digit) as taking their two digits.
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
       and load_nbr ~ ('^' || prefix || '[0-9]{2}[A-Z]{0,3}[0-9]?$')
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

-- Rollback (by hand): drop index public.loads_nbr_unique_sfx_digit; restore dispatch_set_load_nbr from
-- 20261106110000_load_number_suffix.sql and loads_number from 20261110120000_load_number_skip_high.sql.
