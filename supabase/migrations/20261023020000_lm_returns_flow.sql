-- OMS last mile, step 5: return sheets, abort the whole load, close a load (Joel, 2026-10-23).
-- Applied to the live project (Supabase hzagwndglwhcepsirafi) on 2026-10-22, after a rolled-back dry run.
--
-- Builds on lm_core, lm_claim, lm_progress and lm_checklist. Functions only: lm_returns and
-- lm_return_lines already exist (and are empty).
--
-- 1. _lm_make_return(stop): builds a stop's return sheet from the lines that did not go out.
--    Called inside lm_sync the moment a stop ends 'partial' or 'failed', so the office sees
--    the sheet before the driver is back. Safe to call again (one sheet per stop; a line is
--    on it once). Per line, qty = ordered - delivered (a line nobody marked, on a stop that
--    failed without a checklist, returns in full). Reason = the line's reason, else the stop's
--    reason, else 'other'. A damage photo is attached to its line's return line, including a
--    photo registered after the sheet was made. Status stays 'raised' in this phase.
-- 2. lm_sync is replaced. New event, plus the hooks above:
--      abort_load   payload { reason_code, note }. Reason must be a load-level code ('load')
--                   or 'other'. Every open stop ends: an arrived stop where some items were
--                   already delivered becomes 'partial' (or 'delivered' if nothing is left to
--                   hand back), every other open stop 'failed', with the abort reason and a
--                   return sheet for whatever did not go out. The load becomes 'completed'
--                   with aborted_at, abort_reason and abort_note set. Needs the load to be
--                   collected or delivering.
-- 3. lm_close_load(load, note, force): supervisor or manager. completed -> closed, and the
--    phone's token is cleared, so no more photo uploads are accepted. If photos are still
--    waiting to upload it refuses (LM409) unless force is true. Phase 2 will also require the
--    clerk's receipt of the returns before a load can close.
-- 4. _lm_load_json also returns aborted_at, abort_reason and abort_note.
--
-- Rollback is at the bottom.

-- ------------------------------------------------------------------
-- 1. Return sheet for a stop
-- ------------------------------------------------------------------
create function public._lm_make_return(p_stop_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare st lm_stops; rid bigint;
begin
  select * into st from lm_stops where id = p_stop_id;
  if not found or st.status not in ('partial', 'failed') then return; end if;

  insert into lm_returns (load_id, stop_id) values (st.load_id, st.id) on conflict (stop_id) do nothing;
  select id into rid from lm_returns where stop_id = st.id;

  insert into lm_return_lines (return_id, stop_line_id, shipment_nbr, line_nbr, inventory_id, description, uom,
                               qty, reason_code, file_id)
  select rid, l.id, l.shipment_nbr, l.line_nbr, l.inventory_id, l.description, l.uom,
         l.expected_qty - coalesce(l.delivered_qty, 0),
         coalesce(l.reason_code, st.fail_reason, 'other'),
         (select f.id from lm_files f where f.line_id = l.id and f.kind = 'damage'
           order by f.taken_at desc nulls last, f.id limit 1)
    from lm_stop_lines l
   where l.stop_id = st.id and l.expected_qty - coalesce(l.delivered_qty, 0) > 0
  on conflict (stop_line_id) do nothing;

  if not exists (select 1 from lm_return_lines where return_id = rid) then
    delete from lm_returns where id = rid;
  end if;
end $$;
revoke all on function public._lm_make_return(bigint) from public, anon, authenticated;

-- ------------------------------------------------------------------
-- 4. The load as the driver app sees it
-- ------------------------------------------------------------------
create or replace function public._lm_load_json(p_load_id bigint) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'load', jsonb_build_object('id', l.id, 'load_nbr', l.load_nbr, 'load_date', l.load_date, 'ship_via', l.ship_via,
              'trucker', coalesce(sv.description, l.ship_via), 'truck_type', l.truck_type, 'status', m.status,
              'claimed_name', m.claimed_name, 'delivering_at', m.delivering_at, 'completed_at', m.completed_at,
              'aborted_at', m.aborted_at, 'abort_reason', m.abort_reason, 'abort_note', m.abort_note),
    'stops', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', st.id, 'customer_id', st.customer_id, 'customer_name', st.customer_name, 'address', st.address,
          'city', st.city, 'phone', st.phone, 'zone', st.zone, 'note', st.delivery_note,
          'seq_suggested', st.seq_suggested, 'seq', st.seq_final, 'status', st.status,
          'on_the_way_at', st.on_the_way_at, 'arrived_at', st.arrived_at, 'completed_at', st.completed_at,
          'receiver_name', st.receiver_name, 'fail_reason', st.fail_reason, 'fail_note', st.fail_note,
          'invoices', coalesce((select jsonb_agg(jsonb_build_object('shipment_nbr', i.shipment_nbr, 'invoice_nbr', i.invoice_nbr)
                                                 order by i.shipment_nbr)
                                  from lm_stop_invoices i where i.stop_id = st.id), '[]'::jsonb),
          'lines', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'shipment_nbr', x.shipment_nbr, 'line_nbr', x.line_nbr,
                                                 'inventory_id', x.inventory_id, 'description', x.description, 'uom', x.uom,
                                                 'expected', x.expected_qty, 'delivered', x.delivered_qty,
                                                 'result', x.result, 'reason', x.reason_code, 'note', x.note)
                                                 order by x.shipment_nbr, x.line_nbr)
                               from lm_stop_lines x where x.stop_id = st.id), '[]'::jsonb),
          'files', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'kind', f.kind, 'line_id', f.line_id,
                                                 'shipment_nbrs', f.shipment_nbrs, 'uploaded', f.uploaded_at is not null)
                                                 order by f.taken_at, f.id)
                               from lm_files f where f.stop_id = st.id), '[]'::jsonb))
             order by st.seq_final)
        from lm_stops st where st.load_id = l.id), '[]'::jsonb),
    'reasons', coalesce((select jsonb_agg(jsonb_build_object('code', rc.code, 'label', rc.label, 'cause', rc.cause,
                                                'applies_to', rc.applies_to) order by rc.sort)
                           from lm_reason_codes rc where rc.active), '[]'::jsonb))
    from loads l
    join lm_loads m on m.load_id = l.id
    left join ship_via_codes sv on sv.ship_via = l.ship_via
   where l.id = p_load_id;
$$;

-- ------------------------------------------------------------------
-- 2. lm_sync (replaces the lm_checklist version)
-- ------------------------------------------------------------------
create or replace function public.lm_sync(p_token text, p_events jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  m lm_loads; ev jsonb; results jsonb := '[]'::jsonb;
  k text; uid uuid; sid bigint; st lm_stops; raw_at timestamptz; at_ts timestamptz;
  lat double precision; lng double precision; acc real; pl jsonb; ok boolean; why text; cur_status text;
  old_order jsonb; new_order jsonb; ooo boolean;
  ln lm_stop_lines; res text; rsn text; qty numeric;
  n_unmarked int; exp_tot numeric; del_tot numeric; n_exc int; outcome text; rcv text; n_pod int; flags jsonb; fr text;
  fid uuid; fkind text; nbrs text[]; lid bigint; tk timestamptz;
  ab record; n_closed int; abort_msg text;
begin
  m := _lm_auth(p_token);
  if jsonb_typeof(p_events) is distinct from 'array' then raise exception 'Events must be a list' using errcode = 'LM409'; end if;
  if jsonb_array_length(p_events) > 200 then raise exception 'Too many events at once' using errcode = 'LM409'; end if;
  perform 1 from lm_loads where load_id = m.load_id for update;

  for ev in select t.e from jsonb_array_elements(p_events) with ordinality t(e, o) order by t.o loop
    ok := true; why := null; st := null; sid := null; ooo := null;
    pl := case when jsonb_typeof(ev->'payload') = 'object' then ev->'payload' else '{}'::jsonb end;
    k := left(coalesce(ev->>'kind', 'unknown'), 40);

    begin uid := (ev->>'event_uuid')::uuid; exception when others then uid := null; end;
    if uid is null then
      results := results || jsonb_build_array(jsonb_build_object('event_uuid', ev->>'event_uuid', 'applied', false, 'reason', 'bad event id'));
      continue;
    end if;
    if exists (select 1 from lm_events where event_uuid = uid) then
      results := results || jsonb_build_array(jsonb_build_object('event_uuid', uid, 'replay', true,
                   'applied', (select applied from lm_events where event_uuid = uid)));
      continue;
    end if;

    begin raw_at := nullif(ev->>'client_at', '')::timestamptz; exception when others then raw_at := null; end;
    at_ts := case when raw_at between now() - interval '24 hours' and now() + interval '5 minutes' then raw_at else now() end;
    begin
      lat := nullif(ev->>'lat', '')::double precision; lng := nullif(ev->>'lng', '')::double precision;
      acc := nullif(ev->>'accuracy', '')::real;
    exception when others then lat := null; lng := null; acc := null; end;
    if lat is not null and (lng is null or lat not between -90 and 90 or lng not between -180 and 180) then
      lat := null; lng := null; acc := null;
    end if;
    begin sid := nullif(ev->>'stop_id', '')::bigint; exception when others then sid := null; end;

    select status into cur_status from lm_loads where load_id = m.load_id;
    if k not in ('seq_edit', 'on_the_way', 'cancel_on_the_way', 'arrived', 'complete', 'line_set', 'file', 'abort_stop', 'abort_load') then
      ok := false; why := 'unknown event';
    elsif cur_status not in ('collected', 'delivering') and not (k = 'file' and cur_status = 'completed') then
      ok := false; why := 'load is ' || cur_status;
    else
      if k not in ('seq_edit', 'abort_load') then
        select * into st from lm_stops where id = sid and load_id = m.load_id for update;
        if not found then ok := false; why := 'unknown stop'; sid := null; end if;
      else
        sid := null;
      end if;

      if ok then
        if k = 'seq_edit' then
          begin
            if jsonb_typeof(pl->'order') is distinct from 'array'
               or exists (select 1 from jsonb_array_elements_text(pl->'order') t where t !~ '^[0-9]{1,18}$') then
              ok := false; why := 'bad order';
            else
              select coalesce(jsonb_agg(id order by seq_final), '[]'::jsonb) into old_order from lm_stops where load_id = m.load_id;
              with cur as (select id, seq_final, status from lm_stops where load_id = m.load_id),
                   pend_pos as (select seq_final, row_number() over (order by seq_final) rn from cur where status = 'pending'),
                   given as (select val::bigint gid, min(ord) ord
                               from jsonb_array_elements_text(pl->'order') with ordinality t(val, ord) group by 1),
                   want as (select c.id, row_number() over (order by coalesce(g.ord, 1000000 + c.seq_final), c.seq_final) rn
                              from cur c left join given g on g.gid = c.id where c.status = 'pending')
              update lm_stops s set seq_final = pp.seq_final
                from want w join pend_pos pp on pp.rn = w.rn
               where s.id = w.id;
              select coalesce(jsonb_agg(id order by seq_final), '[]'::jsonb) into new_order from lm_stops where load_id = m.load_id;
              pl := pl || jsonb_build_object('old_order', old_order, 'new_order', new_order, 'changed', old_order <> new_order);
            end if;
          exception when others then ok := false; why := 'bad order'; end;

        elsif k = 'on_the_way' then
          if st.status <> 'pending' then ok := false; why := 'stop is ' || st.status;
          elsif exists (select 1 from lm_stops where load_id = m.load_id and id <> st.id and status in ('on_the_way', 'arrived')) then
            ok := false; why := 'finish the stop you are on first';
          else
            ooo := exists (select 1 from lm_stops where load_id = m.load_id and status = 'pending' and seq_final < st.seq_final);
            update lm_stops set status = 'on_the_way', on_the_way_at = at_ts where id = st.id;
            update lm_loads set status = case when status = 'collected' then 'delivering' else status end,
                                delivering_at = coalesce(delivering_at, at_ts)
             where load_id = m.load_id;
            pl := pl || jsonb_build_object('out_of_order', ooo);
          end if;

        elsif k = 'cancel_on_the_way' then
          if st.status <> 'on_the_way' then ok := false; why := 'stop is ' || st.status;
          else update lm_stops set status = 'pending', on_the_way_at = null where id = st.id; end if;

        elsif k = 'arrived' then
          if st.status <> 'on_the_way' then ok := false; why := 'stop is ' || st.status;
          else update lm_stops set status = 'arrived', arrived_at = at_ts where id = st.id; end if;

        elsif k = 'line_set' then
          if st.status <> 'arrived' then ok := false; why := 'stop is ' || st.status;
          else
            ln := null;
            begin
              select * into ln from lm_stop_lines where id = (pl->>'line_id')::bigint and stop_id = st.id for update;
            exception when others then ln := null; end;
            res := pl->>'result';
            rsn := nullif(btrim(coalesce(pl->>'reason_code', '')), '');
            begin qty := nullif(pl->>'qty', '')::numeric; exception when others then qty := null; end;
            if ln.id is null then ok := false; why := 'unknown line';
            elsif res is null or res not in ('delivered', 'short', 'refused', 'damaged') then ok := false; why := 'bad result';
            else
              if res = 'delivered' then qty := ln.expected_qty; rsn := null;
              elsif res = 'refused' then qty := 0;
              end if;
              if res in ('short', 'damaged') and (qty is null or qty < 0 or qty >= ln.expected_qty) then
                ok := false; why := 'quantity must be less than ordered';
              elsif res <> 'delivered' and not exists
                    (select 1 from lm_reason_codes where code = rsn and active and applies_to in ('line', 'both')) then
                ok := false; why := 'a reason is needed';
              elsif res = 'damaged' and not exists (select 1 from lm_reason_codes where code = rsn and cause = 'damaged') then
                ok := false; why := 'damaged needs a damage reason';
              else
                update lm_stop_lines set result = res, delivered_qty = qty, reason_code = rsn,
                       note = nullif(btrim(coalesce(pl->>'note', '')), '')
                 where id = ln.id;
              end if;
            end if;
          end if;

        elsif k = 'file' then
          begin fid := (pl->>'file_id')::uuid; exception when others then fid := null; end;
          fkind := pl->>'kind';
          if fid is null then ok := false; why := 'bad file id';
          elsif fkind is null or fkind not in ('pod', 'damage', 'shortage', 'abort') then ok := false; why := 'bad file kind';
          else
            begin lid := nullif(pl->>'line_id', '')::bigint; exception when others then lid := null; end;
            lid := (select id from lm_stop_lines where id = lid and stop_id = st.id);
            begin tk := nullif(pl->>'taken_at', '')::timestamptz; exception when others then tk := null; end;
            nbrs := coalesce((select array_agg(x) from jsonb_array_elements_text(
                       case when jsonb_typeof(pl->'shipment_nbrs') = 'array' then pl->'shipment_nbrs' else '[]'::jsonb end) x
                      where x in (select shipment_nbr from lm_stop_invoices where stop_id = st.id)), '{}');
            insert into lm_files (id, load_id, stop_id, kind, storage_path, shipment_nbrs, line_id, taken_at, device_id)
            values (fid, m.load_id, st.id, fkind, m.load_id::text || '/' || st.id::text || '/' || fid::text || '.jpg',
                    nbrs, lid, tk, m.claimed_device)
            on conflict (id) do nothing;
            -- a damage photo that arrives after the return sheet was made joins its return line
            if lid is not null and fkind = 'damage' then
              update lm_return_lines set file_id = fid where stop_line_id = lid and file_id is null;
            end if;
          end if;

        elsif k = 'abort_stop' then
          rsn := nullif(btrim(coalesce(pl->>'reason_code', '')), '');
          if st.status not in ('pending', 'on_the_way', 'arrived') then ok := false; why := 'stop is ' || st.status;
          elsif not exists (select 1 from lm_reason_codes where code = rsn and active and applies_to in ('stop', 'both')) then
            ok := false; why := 'a reason is needed';
          else
            update lm_stops set status = 'failed', fail_reason = rsn, fail_note = nullif(btrim(coalesce(pl->>'note', '')), ''),
                   completed_at = at_ts
             where id = st.id;
            perform _lm_make_return(st.id);
          end if;

        elsif k = 'abort_load' then
          rsn := nullif(btrim(coalesce(pl->>'reason_code', '')), '');
          abort_msg := nullif(btrim(coalesce(pl->>'note', '')), '');
          if not exists (select 1 from lm_reason_codes where code = rsn and active and (applies_to = 'load' or code = 'other')) then
            ok := false; why := 'a reason is needed';
          else
            n_closed := 0;
            for ab in select id, status from lm_stops where load_id = m.load_id and status in ('pending', 'on_the_way', 'arrived') order by seq_final loop
              n_closed := n_closed + 1;
              if ab.status = 'arrived' and exists (select 1 from lm_stop_lines where stop_id = ab.id and delivered_qty > 0) then
                if exists (select 1 from lm_stop_lines where stop_id = ab.id and expected_qty - coalesce(delivered_qty, 0) > 0) then
                  update lm_stops set status = 'partial', fail_reason = rsn, fail_note = abort_msg, completed_at = at_ts where id = ab.id;
                else   -- everything at this stop had already been handed over: it is simply delivered
                  update lm_stops set status = 'delivered', completed_at = at_ts where id = ab.id;
                end if;
              else
                update lm_stops set status = 'failed', fail_reason = rsn, fail_note = abort_msg, completed_at = at_ts where id = ab.id;
              end if;
              perform _lm_make_return(ab.id);
            end loop;
            update lm_loads set status = 'completed', completed_at = at_ts, aborted_at = at_ts, abort_reason = rsn, abort_note = abort_msg
             where load_id = m.load_id;
            pl := pl || jsonb_build_object('stops_closed', n_closed);
          end if;

        elsif k = 'complete' then
          if st.status <> 'arrived' then ok := false; why := 'stop is ' || st.status;
          else
            select count(*) into n_unmarked from lm_stop_lines where stop_id = st.id and result is null;
            if n_unmarked > 0 then ok := false; why := n_unmarked::text || ' lines not marked';
            else
              select coalesce(sum(expected_qty), 0), coalesce(sum(delivered_qty), 0), count(*) filter (where result <> 'delivered')
                into exp_tot, del_tot, n_exc from lm_stop_lines where stop_id = st.id;
              outcome := case when exp_tot > 0 and del_tot = 0 then 'failed' when n_exc > 0 then 'partial' else 'delivered' end;
              rcv := nullif(btrim(coalesce(pl->>'receiver_name', '')), '');
              select count(*) into n_pod from lm_files where stop_id = st.id and kind = 'pod';
              flags := '[]'::jsonb;
              fr := null;
              if outcome <> 'failed' then
                if n_pod = 0 then flags := flags || '"no_photo"'::jsonb; end if;
                if rcv is null then flags := flags || '"no_receiver"'::jsonb; end if;
              else
                select reason_code into fr from lm_stop_lines where stop_id = st.id and reason_code is not null
                 group by reason_code order by count(*) desc, reason_code limit 1;
                fr := coalesce(fr, 'customer_refused');
              end if;
              update lm_stops set status = outcome, completed_at = at_ts, receiver_name = rcv, fail_reason = fr where id = st.id;
              pl := pl || jsonb_build_object('outcome', outcome, 'flags', flags);
              if outcome in ('partial', 'failed') then perform _lm_make_return(st.id); end if;
            end if;
          end if;
        end if;

        if ok and k in ('complete', 'abort_stop')
           and not exists (select 1 from lm_stops where load_id = m.load_id and status in ('pending', 'on_the_way', 'arrived')) then
          update lm_loads set status = 'completed', completed_at = at_ts where load_id = m.load_id and status in ('collected', 'delivering');
        end if;
      end if;
    end if;

    if ok and k in ('on_the_way', 'arrived', 'complete', 'abort_stop', 'abort_load') and lat is null then
      pl := pl || jsonb_build_object('gps', 'missing');
    end if;
    perform _lm_event(m.load_id, k, 'driver', p_stop_id := sid, p_device := m.claimed_device, p_client_at := raw_at,
                      p_lat := lat, p_lng := lng, p_accuracy := acc, p_payload := pl, p_event := uid,
                      p_applied := ok, p_reject := why);
    results := results || jsonb_build_array(jsonb_build_object('event_uuid', uid, 'applied', ok, 'reason', why));
  end loop;

  return jsonb_build_object('results', results, 'data', _lm_load_json(m.load_id));
end $$;

-- ------------------------------------------------------------------
-- 3. Close a load
-- ------------------------------------------------------------------
create function public.lm_close_load(p_load_id bigint, p_note text default null, p_force boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m lm_loads; waiting int;
begin
  if auth.uid() is null or not (dispatch_has_role('supervisor') or dispatch_has_role('manager')) then
    raise exception 'Only a supervisor or manager can close a load' using errcode = '42501';
  end if;
  select * into m from lm_loads where load_id = p_load_id for update;
  if not found then raise exception 'That load has no last-mile record'; end if;
  if m.status = 'closed' then raise exception 'That load is already closed'; end if;
  if m.status <> 'completed' then
    raise exception 'That load is % and not finished yet. Wait for the driver, or unassign it.', m.status;
  end if;
  select count(*) into waiting from lm_files where load_id = p_load_id and uploaded_at is null;
  if waiting > 0 and not p_force then
    raise exception '% photo(s) have not uploaded yet. Closing now stops them uploading.', waiting using errcode = 'LM409';
  end if;
  update lm_loads set status = 'closed', closed_at = now(), closed_by = dispatch_actor_name(), token_hash = null
   where load_id = p_load_id;
  perform _lm_event(p_load_id, 'close', 'office', p_actor := dispatch_actor_name(),
                    p_payload := jsonb_build_object('note', nullif(btrim(coalesce(p_note, '')), ''), 'photos_not_uploaded', waiting));
  return jsonb_build_object('closed', true, 'photos_not_uploaded', waiting);
end $$;
revoke all on function public.lm_close_load(bigint, text, boolean) from public, anon;
grant execute on function public.lm_close_load(bigint, text, boolean) to authenticated;

-- ------------------------------------------------------------------
-- Rollback (by hand). lm_sync and _lm_load_json go back to the lm_checklist versions by
-- re-running those definitions from 20261022230000_lm_checklist.sql.
-- ------------------------------------------------------------------
-- drop function public.lm_close_load(bigint, text, boolean);
-- drop function public._lm_make_return(bigint);
