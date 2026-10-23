-- OMS last mile, step 6: Control Tower (Joel, 2026-10-23).
-- Applied to the live project (Supabase hzagwndglwhcepsirafi) on 2026-10-22, after a rolled-back dry run.
--
-- Read-only helpers for the Control Tower page (tower.html), plus realtime.
--
-- 1. lm_board(env, date, idle_min, dwell_min, waiting_min): staff only. One call returns the
--    day's board: every checker-confirmed load of that env and date, plus loads from earlier
--    days that have a last-mile record and are not closed yet (carried = true). Per load:
--    status, who collected it and when, stops done / delivered / partial / failed, the stop
--    the driver is at (name, status, since) and the next waiting stop, time of last activity,
--    return sheets and lines, photos not yet uploaded, and an `attention` list.
--
--    Attention rules (thresholds are the function's parameters; the page passes its own):
--      bad   the driver reported something missing at the scan
--      bad   the driver stopped the load (reason)
--      bad   stops not delivered
--      warn  the load moved to another phone / was rescanned
--      warn  a phone that last ran a different trucker claimed it
--      warn  stops finished with no photo / with no receiver name
--      warn  photos have not uploaded yet
--      warn  no activity for idle_min minutes while collected or delivering
--      warn  at one stop for dwell_min minutes or more
--      info  the sheet was issued waiting_min minutes ago and nobody has collected the load
--
-- 2. lm_find_invoice(number): staff only. Finds an invoice (shipment) number on any date and
--    returns the stop, the load, the times, who received it, where the driver pressed
--    Arrived / Finish (from the GPS in those events) and the photos. For "the customer
--    says they never got it".
-- 3. lm_events joins the realtime publication, so the page hears about new events at once.
--    Only lm_events is published: lm_loads holds the claim code and token hash, and realtime
--    does not honour column-level grants, so publishing it would show those to every staff
--    browser. Every state change already writes an event, so events are enough.
--    RLS applies: only staff (lm_staff()) receive them.
-- 4. An index so finding an invoice by number is quick.
--
-- Rollback is at the bottom.

-- ------------------------------------------------------------------
-- 4. Invoice lookup index
-- ------------------------------------------------------------------
create index lm_stop_invoices_shipment on public.lm_stop_invoices (shipment_nbr);
create index lm_stop_invoices_invoice on public.lm_stop_invoices (invoice_nbr) where invoice_nbr is not null;

-- ------------------------------------------------------------------
-- 3. Realtime
-- ------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                      and schemaname = 'public' and tablename = 'lm_events') then
    alter publication supabase_realtime add table public.lm_events;
  end if;
end $$;

-- ------------------------------------------------------------------
-- 1. The board
-- ------------------------------------------------------------------
create function public.lm_board(p_env text, p_date date, p_idle_min int default 45,
                                p_dwell_min int default 40, p_waiting_min int default 60) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare res jsonb;
begin
  if not lm_staff() then raise exception 'Your account can''t see Control Tower' using errcode = '42501'; end if;
  if p_env not in ('live', 'test') then raise exception 'Unknown env %', p_env; end if;

  with base as (
    select l.id, l.load_nbr, l.load_date, l.wave, l.ship_via, l.contractor, l.truck_type,
           (l.load_date < p_date) as carried, sv.description as trucker,
           m.load_id is not null as has_sheet, m.status as lm_status, m.claimed_name, m.claimed_at, m.shortage_note,
           m.aborted_at, m.abort_reason, m.abort_note, m.completed_at, m.closed_at, m.created_at as sheet_created_at
      from loads l
      left join lm_loads m on m.load_id = l.id
      left join ship_via_codes sv on sv.ship_via = l.ship_via
     where l.env = p_env and l.check_status = 'confirmed' and l.status in ('done', 'partial')
       and (l.load_date = p_date or (l.load_date < p_date and m.load_id is not null and m.status <> 'closed'))
  ),
  st as (
    select s.load_id, count(*) total,
           count(*) filter (where s.status in ('delivered', 'partial', 'failed')) done,
           count(*) filter (where s.status = 'delivered') delivered,
           count(*) filter (where s.status = 'partial') partial,
           count(*) filter (where s.status = 'failed') failed
      from lm_stops s where s.load_id in (select id from base) group by s.load_id
  ),
  cur as (
    select distinct on (s.load_id) s.load_id, s.customer_name, s.status, coalesce(s.arrived_at, s.on_the_way_at) since
      from lm_stops s where s.load_id in (select id from base) and s.status in ('on_the_way', 'arrived')
     order by s.load_id, s.seq_final
  ),
  nxt as (
    select distinct on (s.load_id) s.load_id, s.customer_name
      from lm_stops s where s.load_id in (select id from base) and s.status = 'pending'
     order by s.load_id, s.seq_final
  ),
  ev as (
    select e.load_id, max(e.server_at) last_event_at, min(e.server_at) filter (where e.kind = 'ready') sheet_at,
           count(*) filter (where e.kind = 'rescan') rescans,
           count(*) filter (where e.kind = 'rescan' and e.payload->>'took_over' = 'true') takeovers,
           count(*) filter (where e.kind in ('claim', 'rescan') and e.payload->>'soft_mismatch' = 'true') soft_claims,
           count(*) filter (where e.kind = 'complete' and (e.payload->'flags') ? 'no_photo') no_photo,
           count(*) filter (where e.kind = 'complete' and (e.payload->'flags') ? 'no_receiver') no_receiver
      from lm_events e
      join base b on b.id = e.load_id
     -- only the load's current round: nothing before its sheet was made, nothing before its latest unassign
     where e.applied and b.has_sheet and e.server_at >= b.sheet_created_at
       and e.id > coalesce((select max(u.id) from lm_events u where u.load_id = e.load_id and u.kind = 'unassign'), 0)
     group by e.load_id
  ),
  rt as (
    select r.load_id, count(distinct r.id) sheets, count(rl.id) lines
      from lm_returns r left join lm_return_lines rl on rl.return_id = r.id
     where r.load_id in (select id from base) group by r.load_id
  ),
  ph as (
    select f.load_id, count(*) filter (where f.uploaded_at is null) pending, count(*) total
      from lm_files f where f.load_id in (select id from base) group by f.load_id
  )
  select coalesce(jsonb_agg(r_obj order by r_obj->>'load_date', r_obj->>'wave', r_obj->>'load_nbr'), '[]'::jsonb) into res
  from (
    select jsonb_build_object(
      'load_id', b.id, 'load_nbr', b.load_nbr, 'load_date', b.load_date, 'wave', b.wave, 'carried', b.carried,
      'ship_via', b.ship_via, 'trucker', coalesce(b.trucker, b.ship_via), 'contractor', b.contractor, 'truck_type', b.truck_type,
      'status', case when not b.has_sheet then 'no_sheet' else b.lm_status end,
      'aborted_at', b.aborted_at, 'abort_reason', b.abort_reason, 'abort_note', b.abort_note,
      'claimed_name', b.claimed_name, 'claimed_at', b.claimed_at, 'completed_at', b.completed_at, 'closed_at', b.closed_at,
      'shortage_note', b.shortage_note,
      'stops_total', coalesce(st.total, 0), 'stops_done', coalesce(st.done, 0), 'stops_delivered', coalesce(st.delivered, 0),
      'stops_partial', coalesce(st.partial, 0), 'stops_failed', coalesce(st.failed, 0),
      'current_stop', case when cur.load_id is not null then jsonb_build_object('name', cur.customer_name, 'status', cur.status, 'since', cur.since) end,
      'next_stop', nxt.customer_name,
      'last_event_at', ev.last_event_at,
      'return_sheets', coalesce(rt.sheets, 0), 'return_lines', coalesce(rt.lines, 0),
      'photos_pending', coalesce(ph.pending, 0), 'photos_total', coalesce(ph.total, 0),
      'rescans', coalesce(ev.rescans, 0),
      'attention', a.attn
    ) as r_obj
    from base b
    left join st on st.load_id = b.id
    left join cur on cur.load_id = b.id
    left join nxt on nxt.load_id = b.id
    left join ev on ev.load_id = b.id
    left join rt on rt.load_id = b.id
    left join ph on ph.load_id = b.id
    left join lm_reason_codes rc on rc.code = b.abort_reason
    cross join lateral (
      select coalesce(jsonb_agg(jsonb_build_object('kind', q.k, 'level', q.lvl, 'text', q.txt) order by q.ord), '[]'::jsonb) attn
      from (
        select 1 ord, 'shortage' k, 'bad' lvl, 'Driver reports something missing: ' || b.shortage_note txt
         where b.shortage_note is not null
        union all
        select 2, 'aborted', 'bad', 'Driver stopped the load: ' || coalesce(rc.label, b.abort_reason) || coalesce(' · ' || b.abort_note, '')
         where b.aborted_at is not null
        union all
        select 3, 'failed', 'bad', st.failed || ' stop(s) not delivered'
         where coalesce(st.failed, 0) > 0 and b.aborted_at is null
        union all
        select 4, 'moved', 'warn', case when ev.takeovers > 0 then 'Load was moved to another phone' else 'Load was rescanned ' || ev.rescans || ' time(s)' end
         where coalesce(ev.rescans, 0) > 0
        union all
        select 5, 'soft', 'warn', 'Claimed on a phone that last ran a different trucker'
         where coalesce(ev.soft_claims, 0) > 0
        union all
        select 6, 'no_photo', 'warn', ev.no_photo || ' stop(s) finished with no photo of the signed invoice'
         where coalesce(ev.no_photo, 0) > 0
        union all
        select 7, 'no_receiver', 'warn', ev.no_receiver || ' stop(s) finished with no receiver name'
         where coalesce(ev.no_receiver, 0) > 0
        union all
        select 8, 'photos', 'warn', ph.pending || ' photo(s) not uploaded yet'
         where coalesce(ph.pending, 0) > 0
        union all
        select 9, 'idle', 'warn', 'No activity for ' || round(extract(epoch from now() - ev.last_event_at) / 60)::int || ' min'
         where b.lm_status in ('collected', 'delivering') and ev.last_event_at < now() - make_interval(mins => p_idle_min)
        union all
        select 10, 'dwell', 'warn', 'At ' || cur.customer_name || ' for ' || round(extract(epoch from now() - cur.since) / 60)::int || ' min'
         where cur.status = 'arrived' and cur.since < now() - make_interval(mins => p_dwell_min)
        union all
        select 11, 'waiting', 'info', 'Load sheet issued ' || round(extract(epoch from now() - coalesce(ev.sheet_at, b.sheet_created_at)) / 60)::int || ' min ago and nobody has collected the load'
         where b.lm_status = 'ready' and coalesce(ev.sheet_at, b.sheet_created_at) < now() - make_interval(mins => p_waiting_min)
      ) q
    ) a
  ) t;

  return jsonb_build_object('generated_at', now(), 'env', p_env, 'date', p_date, 'loads', res);
end $$;

-- ------------------------------------------------------------------
-- 2. Find an invoice
-- ------------------------------------------------------------------
create function public.lm_find_invoice(p_nbr text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare n text := nullif(btrim(coalesce(p_nbr, '')), ''); res jsonb;
begin
  if not lm_staff() then raise exception 'Your account can''t see Control Tower' using errcode = '42501'; end if;
  if n is null then return '[]'::jsonb; end if;

  select coalesce(jsonb_agg(x order by x->>'load_date' desc, (x->>'seq')::int), '[]'::jsonb) into res
  from (
    select jsonb_build_object(
      'shipment_nbr', i.shipment_nbr, 'invoice_nbr', i.invoice_nbr,
      'load_id', l.id, 'load_nbr', l.load_nbr, 'load_date', l.load_date, 'env', l.env, 'ship_via', l.ship_via,
      'trucker', coalesce(sv.description, l.ship_via), 'claimed_name', m.claimed_name, 'seq', s.seq_final,
      'stop', jsonb_build_object('id', s.id, 'customer', s.customer_name, 'status', s.status,
          'on_the_way_at', s.on_the_way_at, 'arrived_at', s.arrived_at, 'completed_at', s.completed_at,
          'receiver_name', s.receiver_name, 'fail_reason', s.fail_reason, 'fail_note', s.fail_note),
      'arrived_at_gps', (select jsonb_build_object('lat', e.lat, 'lng', e.lng, 'accuracy_m', e.accuracy_m, 'at', e.server_at)
                           from lm_events e where e.stop_id = s.id and e.kind = 'arrived' and e.applied and e.lat is not null
                          order by e.id desc limit 1),
      'finished_at_gps', (select jsonb_build_object('lat', e.lat, 'lng', e.lng, 'accuracy_m', e.accuracy_m, 'at', e.server_at)
                            from lm_events e where e.stop_id = s.id and e.kind in ('complete', 'abort_stop') and e.applied and e.lat is not null
                           order by e.id desc limit 1),
      'files', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'kind', f.kind, 'storage_path', f.storage_path,
                                    'uploaded', f.uploaded_at is not null, 'covers_invoice', i.shipment_nbr = any (f.shipment_nbrs))
                                    order by f.taken_at, f.id)
                           from lm_files f where f.stop_id = s.id), '[]'::jsonb),
      'lines_not_delivered', (select count(*) from lm_stop_lines x where x.stop_id = s.id and x.shipment_nbr = i.shipment_nbr
                               and x.expected_qty - coalesce(x.delivered_qty, 0) > 0 and x.result is distinct from 'delivered')
    ) as x
    from lm_stop_invoices i
    join lm_stops s on s.id = i.stop_id
    join loads l on l.id = s.load_id
    left join lm_loads m on m.load_id = l.id
    left join ship_via_codes sv on sv.ship_via = l.ship_via
   where i.shipment_nbr = n or i.invoice_nbr = n
   limit 10
  ) t;
  return res;
end $$;

revoke all on function public.lm_board(text, date, int, int, int) from public, anon;
revoke all on function public.lm_find_invoice(text) from public, anon;
grant execute on function public.lm_board(text, date, int, int, int) to authenticated;
grant execute on function public.lm_find_invoice(text) to authenticated;

-- ------------------------------------------------------------------
-- Rollback (by hand)
-- ------------------------------------------------------------------
-- drop function public.lm_find_invoice(text);
-- drop function public.lm_board(text, date, int, int, int);
-- alter publication supabase_realtime drop table public.lm_events;
-- drop index public.lm_stop_invoices_invoice;
-- drop index public.lm_stop_invoices_shipment;
