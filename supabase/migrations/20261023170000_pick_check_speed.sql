-- Picker / checker speed (Joel, 2026-10-23).
--
-- 1. dispatch_pick_bundle(load_ids, with_checks): one call returns what the picker and checker
--    screens used to fetch with a request per load plus three more (pick lists, areas picked,
--    areas staged and, for the checker, saved check lines).
-- 2. The pick / check tables join the realtime publication, so a save on one tablet shows on the
--    other within a second or two. RLS applies (dispatch_has_role()); the pages only use the
--    event as a nudge to re-read, never the row itself.
--
-- Rollback at the bottom.

create function public.dispatch_pick_bundle(p_load_ids bigint[], p_with_checks boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not dispatch_has_role() then raise exception 'Your account has no dispatch role' using errcode = '42501'; end if;
  return jsonb_build_object(
    'picks',  coalesce((select jsonb_agg(to_jsonb(x) || jsonb_build_object('load_id', l.id))
                          from unnest(p_load_ids) as l(id), lateral dispatch_pick_list(l.id) x), '[]'::jsonb),
    'done',   coalesce((select jsonb_agg(to_jsonb(s)) from pick_area_status s where s.load_id = any(p_load_ids)), '[]'::jsonb),
    'staged', coalesce((select jsonb_agg(to_jsonb(s)) from stage_area_status s where s.load_id = any(p_load_ids)), '[]'::jsonb),
    'checks', case when p_with_checks
                   then coalesce((select jsonb_agg(to_jsonb(c)) from check_lines c where c.load_id = any(p_load_ids)), '[]'::jsonb)
                   else '[]'::jsonb end);
end $$;
revoke all on function public.dispatch_pick_bundle(bigint[], boolean) from public, anon;
grant execute on function public.dispatch_pick_bundle(bigint[], boolean) to authenticated;

do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['pick_lines', 'pick_area_status', 'stage_area_status', 'check_lines', 'loads'] loop
      if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                      and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

-- Rollback:
-- alter publication supabase_realtime drop table public.pick_lines, public.pick_area_status,
--   public.stage_area_status, public.check_lines, public.loads;
-- drop function public.dispatch_pick_bundle(bigint[], boolean);
