-- Load numbers count per working day (creation day), not per shipment date (Joel, 2026-11-04).
--
-- 20261103120000_single_load_sequence.sql numbered L-DDMM-NN by the load's SHIPMENT date. But the
-- pickers work tomorrow's shipment date the evening before and carry on the same 1..N run as the
-- morning (their Excel workbook goes #1..#34 across both dates, e.g. 14 loads dated 4 Nov then
-- 20 loads dated 5 Nov = #34). A shipment-date counter restarted at 01 every afternoon.
--
-- Now DDMM is the day the load was CREATED (Jamaica time), whatever its shipment date. The count
-- restarts at 01 on the first load created after midnight. The number is fixed at creation:
-- changing a load's date or wave later does not renumber it (numbers have already reached
-- Acumatica and the printed sheets).
--
-- The next number is the highest already used under that day's prefix, plus 1, so nothing already
-- issued is touched or clashes. On 4 Nov that means new loads continue at L-0411-25; the 20 loads
-- created on 4 Nov for 5 Nov (L-0511-01..20, 8 already written to Acumatica) stay as they are, so
-- 5 Nov carries on from L-0511-21 and 6 Nov is the first day to start at 01.

create or replace function public.loads_number() returns trigger
language plpgsql set search_path = public as $$
declare
  work_day date := (now() at time zone 'America/Jamaica')::date;
  prefix   text := 'L-' || to_char((now() at time zone 'America/Jamaica')::date, 'DDMM') || '-';
begin
  if tg_op = 'INSERT' then
    perform pg_advisory_xact_lock(hashtext('loads:' || new.env || work_day::text));
    -- created_at limit: DDMM repeats every year, so ignore last year's numbers.
    select coalesce(max(substr(load_nbr, length(prefix) + 1)::int), 0) + 1 into new.seq
      from public.loads
     where env = new.env
       and load_nbr ~ ('^' || prefix || '[0-9]+$')
       and created_at > now() - interval '180 days';
    new.load_nbr := prefix || lpad(new.seq::text, 2, '0');
  end if;
  new.updated_at := now();
  return new;
end $$;

-- seq now counts per creation day, so two loads for the same shipment date can legitimately share
-- a seq (created on different days). Uniqueness moves to the number itself.
alter table public.loads drop constraint if exists loads_env_load_date_wave_seq_key;
drop index if exists public.loads_env_load_date_wave_seq_key;
drop index if exists public.loads_one_sequence_per_day;
create unique index if not exists loads_nbr_unique on public.loads (env, load_nbr)
  where load_nbr ~ '^L-[0-9]{4}-[0-9]+$';

comment on column public.loads.load_nbr is 'L-DDMM-NN, set by trigger when the load is created; DDMM is the creation day (Jamaica), not the shipment date. Loads up to 3 Nov 2026: L-MMDD-AM/PM/ACU-NN by shipment date; 4 Nov: L-DDMM-NN by shipment date (to L-0511-20); after that by creation day.';
