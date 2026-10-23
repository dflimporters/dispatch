-- OMS last mile, step 4: checklist, reason codes, proof of delivery (Joel, 2026-10-22).
-- Applied to the live project (Supabase hzagwndglwhcepsirafi) on 2026-10-22, after a rolled-back dry run.
--
-- Builds on lm_core, lm_claim and lm_progress.
--
-- 1. lm_files: the photo's row now exists before its bytes do (the phone registers the
--    photo with a 'file' event, then uploads it when it has signal), so uploaded_at is
--    empty until the upload finishes. Adds line_id (a damage photo belongs to a line),
--    mime and bytes. The table is still empty.
-- 2. Staff can read the private lm-pod bucket (signed links in the office view), and
--    nobody else can: this is the bucket's only policy.
-- 3. Two helper functions for the lm-upload edge function (service role only): check a
--    phone's token against a file and return its storage path, and mark it uploaded.
-- 4. lm_sync is replaced with the new events. Everything from lm_progress still applies.
--      line_set    stop must be 'arrived'. payload { line_id, result, qty, reason_code, note }
--                  result: delivered (qty = ordered), short (qty below ordered), refused
--                  (qty 0), damaged (qty below ordered, damage reason). Anything but
--                  delivered needs an active line reason code. A line can be re-marked.
--      file        registers a photo: { file_id, kind pod|damage|shortage|abort,
--                  shipment_nbrs[], line_id?, taken_at }. Any stop state; also accepted
--                  after the load is 'completed' (a late photo), never after it is closed.
--      abort_stop  pending / on_the_way / arrived -> failed. payload { reason_code, note }
--                  with an active stop reason code. Lines are left as they are.
--      complete    stop must be 'arrived' and every line marked. The server works out the
--                  outcome: nothing delivered -> failed (reason = the lines' commonest
--                  reason, else customer_refused); any line not in full -> partial; else
--                  delivered. A missing POD photo or receiver name does not block: the
--                  event is flagged no_photo / no_receiver (payload.flags) for the office.
--    When no stop is left open after complete or abort_stop the load becomes 'completed'.
-- 5. _lm_load_json also returns each stop's files and failure reason, and each line's note.
--
-- Not here: the return sheet (step 5) and aborting the whole load (step 5).
--
-- Rollback is at the bottom.

-- ------------------------------------------------------------------
-- 1. lm_files
-- ------------------------------------------------------------------
alter table public.lm_files alter column uploaded_at drop not null;
alter table public.lm_files alter column uploaded_at drop default;
alter table public.lm_files add column line_id bigint, add column mime text, add column bytes int;

-- ------------------------------------------------------------------
-- 2. Staff can read the bucket
-- ------------------------------------------------------------------
create policy lm_pod_staff_read on storage.objects for select to authenticated
  using (bucket_id = 'lm-pod' and public.lm_staff());

-- ------------------------------------------------------------------
-- 3. Helpers for the lm-upload edge function (service role only)
-- ------------------------------------------------------------------
create function public.lm_file_authorize(p_token text, p_file uuid) returns text
language plpgsql security definer set search_path = public as $$
declare m lm_loads; path text;
begin
  m := _lm_auth(p_token);
  select storage_path into path from lm_files where id = p_file and load_id = m.load_id;
  if path is null then raise exception 'Unknown file' using errcode = 'LM404'; end if;
  return path;
end $$;

create function public.lm_file_uploaded(p_file uuid, p_bytes int, p_mime text) returns void
language sql security definer set search_path = public as $$
  update lm_files set uploaded_at = coalesce(uploaded_at, now()), bytes = p_bytes, mime = left(p_mime, 40) where id = p_file;
$$;

revoke all on function public.lm_file_authorize(text, uuid)      from public, anon, authenticated;
revoke all on function public.lm_file_uploaded(uuid, int, text)  from public, anon, authenticated;
grant execute on function public.lm_file_authorize(text, uuid)     to service_role;
grant execute on function public.lm_file_uploaded(uuid, int, text) to service_role;

-- ------------------------------------------------------------------
-- 5. The load as the driver app sees it
-- ------------------------------------------------------------------
create or replace function public._lm_load_json(p_load_id bigint) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'load', jsonb_build_object('id', l.id, 'load_nbr', l.load_nbr, 'load_date', l.load_date, 'ship_via', l.ship_via,
              'trucker', coalesce(sv.description, l.ship_via), 'truck_type', l.truck_type, 'status', m.status,
              'claimed_name', m.claimed_name, 'delivering_at', m.delivering_at, 'completed_at', m.completed_at),
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
-- 4. lm_sync (replaces the lm_progress version)
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
    if k not in ('seq_edit', 'on_the_way', 'cancel_on_the_way', 'arrived', 'complete', 'line_set', 'file', 'abort_stop') then
      ok := false; why := 'unknown event';
    elsif cur_status not in ('collected', 'delivering') and not (k = 'file' and cur_status = 'completed') then
      ok := false; why := 'load is ' || cur_status;
    else
      if k <> 'seq_edit' then
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
            end if;
          end if;
        end if;

        if ok and k in ('complete', 'abort_stop')
           and not exists (select 1 from lm_stops where load_id = m.load_id and status in ('pending', 'on_the_way', 'arrived')) then
          update lm_loads set status = 'completed', completed_at = at_ts where load_id = m.load_id and status in ('collected', 'delivering');
        end if;
      end if;
    end if;

    if ok and k in ('on_the_way', 'arrived', 'complete', 'abort_stop') and lat is null then
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
-- Rollback (by hand). lm_sync and _lm_load_json go back to the lm_progress versions by
-- re-running those definitions from 20261022220000_lm_progress.sql.
-- ------------------------------------------------------------------
-- drop policy lm_pod_staff_read on storage.objects;
-- drop function public.lm_file_uploaded(uuid, int, text);
-- drop function public.lm_file_authorize(text, uuid);
-- alter table public.lm_files drop column line_id, drop column mime, drop column bytes;
-- alter table public.lm_files alter column uploaded_at set default now();
-- (and set uploaded_at not null again once no row has it empty)
