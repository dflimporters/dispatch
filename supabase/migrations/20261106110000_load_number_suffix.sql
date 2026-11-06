-- Load numbers can carry a short letter suffix, e.g. 05ADD, for loads that become an addition to
-- a load already done (Joel, 2026-11-06). Typing "05ADD" (max 5 characters) gives
-- L-<the load's DDMM>-05ADD. Digits are padded to two (5ADD -> 05ADD). Up to 3 letters.
-- Full form L-DDMM-NN[A-Z]{0,3} is also accepted. Still unique per env.

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
  -- Just the number, optionally with letters (5, 05, 99, 05ADD; max 5 characters): keep the load's own
  -- L-DDMM- and pad the digits to two. A load still on an old-format number (L-MMDD-AM-NN) gets
  -- today's DDMM (Jamaica time).
  m := regexp_match(nbr, '^([0-9]{1,4})([A-Z]{0,3})$');
  if m is not null and length(nbr) <= 5 then
    nbr := coalesce(case when l.load_nbr ~ '^L-[0-9]{4}-[0-9]+' then substr(l.load_nbr, 1, 7) end,
                    'L-' || to_char((now() at time zone 'America/Jamaica')::date, 'DDMM') || '-')
           || lpad(m[1], 2, '0') || m[2];
  elsif nbr !~ '^L-[0-9]{4}-[0-9]{2,}[A-Z]{0,3}$' then
    raise exception 'Enter the load number, e.g. 5 or 05ADD (or the full L-0611-05)';
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

-- Uniqueness must cover the suffixed numbers too.
drop index if exists public.loads_nbr_unique;
create unique index loads_nbr_unique on public.loads (env, load_nbr)
  where load_nbr ~ '^L-[0-9]{4}-[0-9]+[A-Z]{0,3}$';
