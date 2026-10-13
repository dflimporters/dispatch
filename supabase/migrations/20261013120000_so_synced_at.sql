-- When so_ordered_items was last refreshed, for the Transfers page's "synced N min ago"
-- badge. The page used to read the table directly, but signed-in users have no table
-- grant on it (it holds prices and costs), so the badge never showed. This exposes
-- only the timestamp, to dispatch roles.
create function public.dispatch_so_synced_at() returns timestamptz
language sql stable security definer set search_path = public as $$
  select max(synced_at) from so_ordered_items where dispatch_has_role();
$$;
revoke all on function public.dispatch_so_synced_at() from public, anon;
grant execute on function public.dispatch_so_synced_at() to authenticated;
