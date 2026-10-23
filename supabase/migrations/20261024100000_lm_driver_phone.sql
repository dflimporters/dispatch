-- Driver of the day gives his phone number when he scans and claims a load.
-- Stored on lm_loads.claimed_phone, readable by staff (Control Tower) like claimed_name.
-- The old lm_claim becomes _lm_claim_core (not callable by the app); the new lm_claim
-- takes p_phone, checks it, calls the core, then saves the number.

alter table public.lm_loads add column if not exists claimed_phone text;

alter function public.lm_claim(text, uuid, text, boolean, boolean) rename to _lm_claim_core;
revoke all on function public._lm_claim_core(text, uuid, text, boolean, boolean) from public, anon, authenticated;

create function public.lm_claim(p_code text, p_device uuid, p_name text, p_phone text,
                                p_override_soft boolean default false, p_takeover boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ph text := btrim(coalesce(p_phone, '')); r jsonb;
begin
  if length(regexp_replace(ph, '[^0-9]', '', 'g')) < 7 then
    raise exception 'Enter your phone number first' using errcode = 'LM409';
  end if;
  r := _lm_claim_core(p_code, p_device, p_name, p_override_soft, p_takeover);
  update lm_loads set claimed_phone = ph where claim_code = _lm_norm_code(p_code);
  return r;
end $$;

revoke all on function public.lm_claim(text, uuid, text, text, boolean, boolean) from public;
grant execute on function public.lm_claim(text, uuid, text, text, boolean, boolean) to anon, authenticated;

grant select (claimed_phone) on public.lm_loads to authenticated;

-- Rollback (by hand):
-- drop function public.lm_claim(text, uuid, text, text, boolean, boolean);
-- alter function public._lm_claim_core(text, uuid, text, boolean, boolean) rename to lm_claim;
-- grant execute on function public.lm_claim(text, uuid, text, boolean, boolean) to anon, authenticated;
-- alter table public.lm_loads drop column claimed_phone;
