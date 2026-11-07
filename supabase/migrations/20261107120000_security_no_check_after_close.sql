-- OMS last mile: no security check can be recorded once a load is closed (Joel, 2026-11-07).
--
-- The security page let staff fill in the check again after the office had closed the load. The
-- page now shows a closed load read-only; this makes the database refuse it too, so a page left
-- open from before the close cannot add a check either. Only lm_security_submit changes: the
-- body is the 20261026120000 version plus the closed-load guard.
--
-- Rollback: re-run lm_security_submit from 20261026120000_driver_security_contacts.sql.

create or replace function public.lm_security_submit(p_load_id bigint, p_counts jsonb, p_items jsonb, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  n text := nullif(btrim(coalesce(p_note, '')), ''); new_id bigint; res text; mism int := 0; arr jsonb := '[]'::jsonb;
  it jsonb := case when jsonb_typeof(p_items) = 'object' then p_items else '{}'::jsonb end;
  cnt jsonb := case when jsonb_typeof(p_counts) = 'object' then p_counts else '{}'::jsonb end;
  rl record; c numeric; st text;
begin
  if not _lm_security_ok() then raise exception 'Only security, a supervisor or a manager can do this' using errcode = '42501'; end if;
  select status into st from lm_loads where load_id = p_load_id;
  if not found then raise exception 'That load has no last-mile record'; end if;
  if st = 'closed' then raise exception 'That load is already closed. No more checks can be recorded.'; end if;
  for rl in select l.id, l.qty from lm_return_lines l join lm_returns r on r.id = l.return_id where r.load_id = p_load_id order by l.id loop
    begin c := nullif(cnt->>(rl.id::text), '')::numeric; exception when others then c := null; end;
    if c is null or c < 0 then raise exception 'Count every item on the return sheet (enter 0 if it did not come back)'; end if;
    if c <> rl.qty then mism := mism + 1; end if;
    arr := arr || jsonb_build_array(jsonb_build_object('line_id', rl.id, 'expected', rl.qty, 'counted', c));
  end loop;
  res := case when mism = 0 and not exists (select 1 from lm_security_check_items i where i.active and coalesce(it->>i.code, 'false') <> 'true')
              then 'clear' else 'flagged' end;
  if res = 'flagged' and n is null then raise exception 'Something does not match or is not ticked. Say what is wrong in the note.'; end if;
  insert into lm_security_checks (load_id, result, items, counts, note, checked_by, checked_by_id)
  values (p_load_id, res, it, arr, n, dispatch_actor_name(), auth.uid()) returning id into new_id;
  perform _lm_event(p_load_id, 'security_check', 'office', p_actor := dispatch_actor_name(),
                    p_payload := jsonb_build_object('result', res, 'mismatched_lines', mism, 'items', it, 'note', n));
  return jsonb_build_object('id', new_id, 'result', res, 'mismatched_lines', mism);
end $$;
