-- Edit cases per pallet from the Day 0 plan (Transfer tab). Coordinator role. A size of 1 or less
-- (or null) clears the item's size, matching the sheet where 1 means "not set".
create or replace function public.dispatch_set_pallet_size(p_item text, p_cases numeric)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not dispatch_has_role('batcher') then
    raise exception 'Your account doesn''t have the coordinator role' using errcode = '42501';
  end if;
  if nullif(trim(p_item), '') is null then raise exception 'Item is required'; end if;
  if p_cases is null or p_cases <= 1 then
    delete from item_pallet_sizes where inventory_id = trim(p_item);
  else
    insert into item_pallet_sizes (inventory_id, cases_per_pallet) values (trim(p_item), round(p_cases))
    on conflict (inventory_id) do update set cases_per_pallet = excluded.cases_per_pallet;
  end if;
end $$;
revoke all on function public.dispatch_set_pallet_size(text, numeric) from public, anon;
grant execute on function public.dispatch_set_pallet_size(text, numeric) to authenticated;
