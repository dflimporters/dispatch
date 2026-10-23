-- OMS last mile, step 3: route order and stop progress (Joel, 2026-10-22).
-- Applied to the live project (Supabase hzagwndglwhcepsirafi) on 2026-10-22, after a rolled-back dry run.
--
-- Builds on lm_core and lm_claim. Functions only: no new tables or columns. The
-- columns it fills already exist (lm_stops.seq_final, on_the_way_at, arrived_at,
-- completed_at, receiver_name; lm_loads.status, delivering_at, completed_at).
--
-- lm_sync(token, events) is the one call the driver app makes to say what happened.
-- The app saves every press on the phone first (offline queue) and sends the queue in
-- order whenever it has signal. Each event is:
--   { event_uuid, kind, stop_id, client_at, lat, lng, accuracy, payload }
-- The server applies them in order, ignores replays (same event_uuid), and returns a
-- result per event plus the refreshed load. A refused event (wrong state, unknown stop,
-- load finished) is still logged, with applied = false and the reason, never dropped.
--
-- Kinds and rules:
--   seq_edit           payload.order = the driver's full stop order. Only pending stops
--                      move; stops already visited keep their place. Old and new order
--                      are logged so the office can see the change.
--   on_the_way         pending -> on_the_way. One stop en route or arrived at a time.
--                      The first one moves the load to 'delivering'. Starting a stop that
--                      isn't the next pending one is allowed and logged out_of_order.
--   cancel_on_the_way  on_the_way -> pending (a mis-tap).
--   arrived            on_the_way -> arrived.
--   complete           arrived -> delivered (INTERIM: step 4 replaces this with the
--                      checklist and proof of delivery, which can also end a stop
--                      'partial'). When no stop is left open, the load becomes 'completed'.
--
-- Time: the phone's clock is used when it is within 24 hours before, or 5 minutes after,
-- the server's time; otherwise the server's time. The raw phone time is kept in the event.
-- GPS: a press without a position still goes through; its payload is flagged gps = missing.
-- Flag, don't block.
--
-- Also replaces _lm_load_json (from lm_claim) so the app gets the times and receiver name.
--
-- Rollback is at the bottom.

-- ------------------------------------------------------------------
-- The load as the driver app sees it, now with stop times
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
          'receiver_name', st.receiver_name,
          'invoices', coalesce((select jsonb_agg(jsonb_build_object('shipment_nbr', i.shipment_nbr, 'invoice_nbr', i.invoice_nbr)
                                                 order by i.shipment_nbr)
                                  from lm_stop_invoices i where i.stop_id = st.id), '[]'::jsonb),
          'lines', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'shipment_nbr', x.shipment_nbr, 'line_nbr', x.line_nbr,
                                                 'inventory_id', x.inventory_id, 'description', x.description, 'uom', x.uom,
                                                 'expected', x.expected_qty, 'delivered', x.delivered_qty,
                                                 'result', x.result, 'reason', x.reason_code)
                                                 order by x.shipment_nbr, x.line_nbr)
                               from lm_stop_lines x where x.stop_id = st.id), '[]'::jsonb))
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
-- lm_sync
-- ------------------------------------------------------------------
create function public.lm_sync(p_token text, p_events jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  m lm_loads; ev jsonb; results jsonb := '[]'::jsonb;
  k text; uid uuid; sid bigint; st lm_stops; raw_at timestamptz; at_ts timestamptz;
  lat double precision; lng double precision; acc real; pl jsonb; ok boolean; why text; cur_status text;
  old_order jsonb; new_order jsonb; ooo boolean;
begin
  m := _lm_auth(p_token);
  if jsonb_typeof(p_events) is distinct from 'array' then raise exception 'Events must be a list' using errcode = 'LM409'; end if;
  if jsonb_array_length(p_events) > 200 then raise exception 'Too many events at once' using errcode = 'LM409'; end if;
  perform 1 from lm_loads where load_id = m.load_id for update;     -- one sync at a time per load

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
    if k not in ('seq_edit', 'on_the_way', 'cancel_on_the_way', 'arrived', 'complete') then
      ok := false; why := 'unknown event';
    elsif cur_status not in ('collected', 'delivering') then
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

        elsif k = 'complete' then
          if st.status <> 'arrived' then ok := false; why := 'stop is ' || st.status;
          else
            update lm_stops set status = 'delivered', completed_at = at_ts,
                   receiver_name = nullif(btrim(coalesce(pl->>'receiver_name', '')), '')
             where id = st.id;
            if not exists (select 1 from lm_stops where load_id = m.load_id and status in ('pending', 'on_the_way', 'arrived')) then
              update lm_loads set status = 'completed', completed_at = at_ts where load_id = m.load_id;
            end if;
          end if;
        end if;
      end if;
    end if;

    if ok and k in ('on_the_way', 'arrived', 'complete') and lat is null then
      pl := pl || jsonb_build_object('gps', 'missing');
    end if;
    perform _lm_event(m.load_id, k, 'driver', p_stop_id := sid, p_device := m.claimed_device, p_client_at := raw_at,
                      p_lat := lat, p_lng := lng, p_accuracy := acc, p_payload := pl, p_event := uid,
                      p_applied := ok, p_reject := why);
    results := results || jsonb_build_array(jsonb_build_object('event_uuid', uid, 'applied', ok, 'reason', why));
  end loop;

  return jsonb_build_object('results', results, 'data', _lm_load_json(m.load_id));
end $$;

revoke all on function public.lm_sync(text, jsonb) from public;
grant execute on function public.lm_sync(text, jsonb) to anon, authenticated;

-- ------------------------------------------------------------------
-- Rollback (by hand). _lm_load_json goes back to the lm_claim version by re-running
-- that definition from 20261022210000_lm_claim.sql.
-- ------------------------------------------------------------------
-- drop function public.lm_sync(text, jsonb);
