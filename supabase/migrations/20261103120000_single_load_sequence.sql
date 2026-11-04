-- One load-number sequence for the whole day, with no AM/PM in it (Joel, 2026-11-03).
--
-- Before: L-MMDD-AM-NN, L-MMDD-PM-NN and L-MMDD-ACU-NN each counted from 01.
-- Now:    L-DDMM-NN (day first, so 4 Nov is L-0411-01), counting up through the day across every load, however it was made
--         (built in the portal, auto-loaded from Acumatica, invoice or reassign loads).
--         Where a load came from is shown by its tag (ACU / From Acumatica / Picked outside
--         portal), not by the number.
--
-- Past loads keep their numbers. loads_number() only runs on INSERT, or when a load's date
-- changes, so nothing already numbered is touched (those numbers have already reached
-- Acumatica and the printed sheets). Old and new formats sit side by side in history.
--
-- On the day this is applied the count carries on from the highest number already used that
-- day, so new loads never clash with that day's L-MMDD-AM-03 / -PM-02 / -ACU-04. Applying it
-- before the first load of the day keeps the day clean.
--
-- The wave column stays (the batcher still plans AM/PM runs with it). It no longer affects
-- the number: changing a draft's wave does not renumber it.
--
-- NOTE: counts by SHIPMENT date. Superseded the next day by 20261104180000_load_number_by_creation_day.sql.

create or replace function public.loads_number() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.load_date is distinct from old.load_date then
    perform pg_advisory_xact_lock(hashtext('loads:' || new.env || new.load_date::text));
    select coalesce(max(seq), 0) + 1 into new.seq
      from public.loads
     where env = new.env and load_date = new.load_date and id is distinct from new.id;
    new.load_nbr := 'L-' || to_char(new.load_date, 'DDMM') || '-' || lpad(new.seq::text, 2, '0');
  end if;
  new.updated_at := now();
  return new;
end $$;

-- Old days legitimately repeat a seq (AM-01 and PM-01 are both seq 1), so the day-wide unique
-- check can only cover days that have no old-format loads yet. Loads for the next day already
-- exist (4 Nov had ACU and PM loads when this ran), so it starts the day after. The advisory
-- lock above covers the days before that.
do $$
declare first_day date := (now() at time zone 'America/Jamaica')::date + 2;
begin
  execute format(
    'create unique index if not exists loads_one_sequence_per_day on public.loads (env, load_date, seq) where load_date >= %L',
    first_day);
end $$;

comment on column public.loads.load_nbr is 'L-DDMM-NN, set by trigger (loads up to 3 Nov 2026: L-MMDD-AM/PM/ACU-NN)';
