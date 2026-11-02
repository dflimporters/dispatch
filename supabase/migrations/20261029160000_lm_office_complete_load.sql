-- OMS last mile: the office can complete a load from Control Tower (Joel, 2026-10-29).
--
-- For a load that is collected or delivering but that the driver can't or won't finish on the
-- phone (stops left open, phone dead, driver gone home). Supervisor or manager only, and a
-- reason note is required. It does what the driver's "stop the load" does to open stops:
--   * an open stop where some items were already handed over becomes 'partial' (or 'delivered'
--     if nothing is left to hand back);
--   * every other open stop becomes 'failed' with reason 'other' and the note;
--   * each of those gets a return sheet for whatever did not go out (_lm_make_return).
-- The load becomes 'completed' with completed_at set. aborted_at is NOT set: this is not the
-- driver stopping the load, so Control Tower doesn't show "Driver stopped the load".
-- The phone keeps its token, so the driver sees the load finished, and the office then closes it
-- as usual (which still needs the security check). A 'office_complete' event records who did it.
--
-- Rollback: drop function public.lm_complete_load(bigint, text);

create function public.lm_complete_load(p_load_id bigint, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m lm_loads; note text := nullif(btrim(coalesce(p_note, '')), ''); ab record; n_closed int := 0;
begin
  if auth.uid() is null or not (dispatch_has_role('supervisor') or dispatch_has_role('manager')) then
    raise exception 'Only a supervisor or manager can complete a load' using errcode = '42501';
  end if;
  if note is null then raise exception 'Say why the load is being completed from the office'; end if;
  select * into m from lm_loads where load_id = p_load_id for update;
  if not found then raise exception 'That load has no last-mile record'; end if;
  if m.status not in ('collected', 'delivering') then
    raise exception 'That load is % and cannot be completed from here', m.status;
  end if;

  for ab in select id, status from lm_stops where load_id = p_load_id and status in ('pending', 'on_the_way', 'arrived') order by seq_final loop
    n_closed := n_closed + 1;
    if ab.status = 'arrived' and exists (select 1 from lm_stop_lines where stop_id = ab.id and delivered_qty > 0) then
      if exists (select 1 from lm_stop_lines where stop_id = ab.id and expected_qty - coalesce(delivered_qty, 0) > 0) then
        update lm_stops set status = 'partial', fail_reason = 'other', fail_note = note, completed_at = now() where id = ab.id;
      else
        update lm_stops set status = 'delivered', completed_at = now() where id = ab.id;
      end if;
    else
      update lm_stops set status = 'failed', fail_reason = 'other', fail_note = note, completed_at = now() where id = ab.id;
    end if;
    perform _lm_make_return(ab.id);
  end loop;

  update lm_loads set status = 'completed', completed_at = now() where load_id = p_load_id;
  perform _lm_event(p_load_id, 'office_complete', 'office', p_actor := dispatch_actor_name(),
                    p_payload := jsonb_build_object('note', note, 'stops_closed', n_closed));
  return jsonb_build_object('completed', true, 'stops_closed', n_closed);
end $$;
revoke all on function public.lm_complete_load(bigint, text) from public, anon;
grant execute on function public.lm_complete_load(bigint, text) to authenticated;
