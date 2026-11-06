-- The batcher can set the real load number (Joel, 2026-11-06).
--
-- The portal numbered loads itself (L-DDMM-NN), so it drifted from the batchers' own run of
-- numbers. The number the batcher types is now the truth: the trigger still pre-fills the next
-- number when a load is created (portal-built or auto-loaded from Acumatica), and the batcher
-- overwrites it to match their sheet. Format stays L-DDMM-NN, unique per env.
--
-- Allowed on any load (draft, sent, confirmed, Acumatica auto-loads, loads already being picked)
-- until the checker has confirmed it (check_status confirming/confirmed), because the number
-- goes to Acumatica at confirmation. Not renumbering a load with a lowercase/typo: the input is
-- trimmed and upper-cased. The change is logged in the load's history with the old number.
--
-- The next auto number is still the highest used under that day's prefix + 1, so numbers the
-- batcher enters keep the sequence moving forward and never clash.

create or replace function public.dispatch_set_load_nbr(p_id bigint, p_nbr text) returns void
language plpgsql security definer set search_path = public as $$
declare l loads; n loads; nbr text := upper(trim(coalesce(p_nbr, '')));
begin
  perform _dispatch_require('batcher');
  if nbr !~ '^L-[0-9]{4}-[0-9]{2,}$' then
    raise exception 'Load number must look like L-0611-05 (L-DDMM-NN)';
  end if;
  select * into l from loads where id = p_id for update;
  if not found then raise exception 'Load not found (it may have been deleted)'; end if;
  if l.check_status in ('confirming', 'confirmed') then
    raise exception '% has already been checked and confirmed, so its number can''t be changed here', l.load_nbr;
  end if;
  if nbr = l.load_nbr then return; end if;
  if exists (select 1 from loads where env = l.env and load_nbr = nbr and id <> l.id) then
    raise exception '% is already used by another load', nbr;
  end if;
  update loads set load_nbr = nbr, seq = substr(nbr, 8)::int where id = p_id returning * into n;
  perform _dispatch_log(n, 'edit', 'Load number changed from ' || l.load_nbr || ' to ' || n.load_nbr,
                        jsonb_build_object('old_nbr', l.load_nbr, 'new_nbr', n.load_nbr));
end $$;

revoke all on function public.dispatch_set_load_nbr(bigint, text) from public, anon;
grant execute on function public.dispatch_set_load_nbr(bigint, text) to authenticated;
