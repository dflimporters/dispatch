-- OMS last mile, step 2: scan and claim (Joel, 2026-10-22).
-- Applied to the live project (Supabase hzagwndglwhcepsirafi) on 2026-10-22, after a rolled-back dry run.
--
-- Builds on 20261022200000_lm_core.sql. Adds the functions the driver app calls to
-- look at a load (peek), take responsibility for it (claim, or rescan to resume),
-- report a shortage, and the staff functions to print the load sheet and unassign.
--
-- Drivers have no accounts. The functions below are granted to anon and authenticated
-- (a signed-in staff phone must still work) and check a per-load secret instead of a
-- user. The secret is a random 64-hex-character token returned once by lm_claim; only
-- its sha256 is stored (lm_loads.token_hash). A new claim or rescan replaces it, and
-- an unassign clears it, which locks out the old phone with error LM001.
--
-- Error codes the app reacts to (SQLSTATE):
--   LM001  token no longer valid (unassigned, or replaced by a rescan)
--   LM404  code not recognised
--   LM409  can't be claimed (not confirmed yet, finished, or the trucker has another open load)
--   LM410  soft check: this phone last ran a different trucker; resend with p_override_soft
--   LM411  already held by another phone; resend with p_takeover to move it here
--
-- Rules, as agreed:
--   * Claimable once loads.check_status = 'confirmed'.
--   * One open load per trucker (lm_trucker_key): a second claim is refused until the
--     first has left collected/delivering.
--   * Stop order suggestion is zone, then city, then name, until real distances exist.
--   * Unassign is supervisor/manager only and only before any stop has left 'pending'.
--
-- Rollback is at the bottom.

-- ------------------------------------------------------------------
-- Internal helpers
-- ------------------------------------------------------------------

-- Typed or misread codes: drop spaces and dashes, upper-case, O->0, I/L->1.
create function public._lm_norm_code(p_code text) returns text
language sql immutable as $$
  select translate(upper(regexp_replace(coalesce(p_code, ''), '[^0-9A-Za-z]', '', 'g')), 'OIL', '011');
$$;

create function public._lm_hash(p_token text) returns text
language sql immutable set search_path = public, extensions as $$
  select encode(digest(convert_to(coalesce(p_token, ''), 'UTF8'), 'sha256'), 'hex');
$$;

-- The load a token belongs to, or LM001.
create function public._lm_auth(p_token text) returns public.lm_loads
language plpgsql security definer set search_path = public as $$
declare m lm_loads;
begin
  if coalesce(p_token, '') = '' then raise exception 'REVOKED' using errcode = 'LM001'; end if;
  select * into m from lm_loads where token_hash = _lm_hash(p_token);
  if not found then raise exception 'REVOKED' using errcode = 'LM001'; end if;
  return m;
end $$;

-- One row per customer on the load, in the suggested order.
create function public._lm_stop_rows(p_load_id bigint)
returns table (customer_id text, customer_name text, address text, city text, phone text, zone text, seq int)
language sql stable security definer set search_path = public as $$
  select y.customer_id, y.customer_name, y.address, y.city, y.phone, y.zone,
         (row_number() over (order by y.zone nulls last, y.city nulls last, y.customer_name, y.customer_id))::int
    from (
      select coalesce(s.customer_id, '?') customer_id,
             max(coalesce(c.customer_name, s.customer_name)) customer_name,
             max(nullif(btrim(concat_ws(', ', c.address_line1, c.address_line2)), '')) address,
             max(nullif(btrim(c.city), '')) city,
             max(coalesce(nullif(btrim(c.phone1), ''), nullif(btrim(c.phone2), ''))) phone,
             max(coalesce(nullif(btrim(s.shipping_zone), ''), nullif(btrim(c.shipping_zone), ''))) zone
        from loads l
        join load_shipments ls on ls.load_id = l.id
        join lateral (select * from _dispatch_shipments(l.env) x where x.shipment_nbr = ls.shipment_nbr) s on true
        left join lateral (select * from customers cc where cc.customer_id = s.customer_id limit 1) c on true
       where l.id = p_load_id
       group by coalesce(s.customer_id, '?')) y
$$;

-- Copy stops, invoices and lines from the load, once. What the checker let out
-- (check_lines.final_qty) wins over the shipment's own quantity; zero lines are dropped.
create function public._lm_snapshot(p_load_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare l loads;
begin
  select * into l from loads where id = p_load_id;
  if not found then raise exception 'Load not found'; end if;
  if exists (select 1 from lm_stops where load_id = p_load_id) then return; end if;

  insert into lm_stops (load_id, customer_id, customer_name, address, city, phone, zone, seq_suggested, seq_final)
  select p_load_id, r.customer_id, r.customer_name, r.address, r.city, r.phone, r.zone, r.seq, r.seq
    from _lm_stop_rows(p_load_id) r;

  insert into lm_stop_invoices (stop_id, shipment_nbr)
  select st.id, ls.shipment_nbr
    from load_shipments ls
    join lateral (select * from _dispatch_shipments(l.env) x where x.shipment_nbr = ls.shipment_nbr) s on true
    join lm_stops st on st.load_id = p_load_id and st.customer_id = coalesce(s.customer_id, '?')
   where ls.load_id = p_load_id;

  insert into lm_stop_lines (stop_id, shipment_nbr, line_nbr, inventory_id, description, uom, expected_qty)
  select st.id, sl.shipment_nbr, sl.line_nbr, sl.inventory_id, sl.description, sl.uom,
         coalesce(cl.final_qty, sl.shipped_qty)
    from load_shipments ls
    join lateral (select * from _dispatch_shipments(l.env) x where x.shipment_nbr = ls.shipment_nbr) s on true
    join lm_stops st on st.load_id = p_load_id and st.customer_id = coalesce(s.customer_id, '?')
    join shipment_lines sl on sl.env = l.env and sl.shipment_nbr = ls.shipment_nbr
    left join check_lines cl on cl.load_id = p_load_id and cl.shipment_nbr = sl.shipment_nbr and cl.line_nbr = sl.line_nbr
   where ls.load_id = p_load_id and coalesce(cl.final_qty, sl.shipped_qty) > 0;
end $$;

-- Everything the driver app needs to draw the load and work offline.
create function public._lm_load_json(p_load_id bigint) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'load', jsonb_build_object('id', l.id, 'load_nbr', l.load_nbr, 'load_date', l.load_date, 'ship_via', l.ship_via,
              'trucker', coalesce(sv.description, l.ship_via), 'truck_type', l.truck_type, 'status', m.status,
              'claimed_name', m.claimed_name),
    'stops', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', st.id, 'customer_id', st.customer_id, 'customer_name', st.customer_name, 'address', st.address,
          'city', st.city, 'phone', st.phone, 'zone', st.zone, 'note', st.delivery_note,
          'seq_suggested', st.seq_suggested, 'seq', st.seq_final, 'status', st.status,
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
-- Driver functions (anon + authenticated)
-- ------------------------------------------------------------------

-- The review screen. Changes nothing.
create function public.lm_peek(p_code text, p_device uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  m lm_loads; l loads; c text; tkey text; last_t text; state text;
  nstops int; zones jsonb; firsts jsonb; nships int; units numeric; prods int; blocked text; sv_desc text;
begin
  c := _lm_norm_code(p_code);
  select * into m from lm_loads where claim_code = c;
  if not found then raise exception 'Code not recognised' using errcode = 'LM404'; end if;
  select * into l from loads where id = m.load_id;
  tkey := lm_trucker_key(l.ship_via);
  select description into sv_desc from ship_via_codes where ship_via = l.ship_via;
  select last_trucker into last_t from lm_devices where device_id = p_device;

  select count(*), coalesce(jsonb_agg(distinct r.zone) filter (where r.zone is not null), '[]'::jsonb),
         coalesce((select jsonb_agg(f.customer_name order by f.seq) from (select * from _lm_stop_rows(l.id) order by seq limit 3) f), '[]'::jsonb)
    into nstops, zones, firsts
    from _lm_stop_rows(l.id) r;
  select count(*) into nships from load_shipments where load_id = l.id;
  select coalesce(sum(coalesce(cl.final_qty, sl.shipped_qty)), 0), count(distinct sl.inventory_id)
    into units, prods
    from load_shipments ls
    join shipment_lines sl on sl.env = l.env and sl.shipment_nbr = ls.shipment_nbr
    left join check_lines cl on cl.load_id = l.id and cl.shipment_nbr = sl.shipment_nbr and cl.line_nbr = sl.line_nbr
   where ls.load_id = l.id and coalesce(cl.final_qty, sl.shipped_qty) > 0;

  select ol.load_nbr into blocked
    from lm_loads o join loads ol on ol.id = o.load_id
   where o.trucker_key = tkey and o.status in ('collected', 'delivering') and o.load_id <> l.id limit 1;

  state := case
    when l.check_status is distinct from 'confirmed' then 'not_ready'
    when m.status in ('completed', 'closed') then 'finished'
    when m.token_hash is not null then 'held'
    else 'ready' end;

  return jsonb_build_object(
    'state', state,
    'load_nbr', l.load_nbr, 'load_date', l.load_date, 'wave', l.wave, 'env', l.env,
    'ship_via', l.ship_via, 'trucker_key', tkey, 'trucker', coalesce(sv_desc, l.ship_via), 'truck_type', l.truck_type,
    'stops', nstops, 'shipments', nships, 'units', units, 'products', prods,
    'zones', zones, 'first_customers', firsts,
    'checked_at', l.checked_at,
    'held_by', case when state = 'held' then m.claimed_name end,
    'held_by_this_device', (state = 'held' and m.claimed_device is not distinct from p_device),
    'soft_mismatch', (last_t is not null and last_t <> tkey), 'last_trucker', last_t,
    'blocked_by', blocked,
    'can_claim', (state in ('ready', 'held') and blocked is null));
end $$;

-- Take responsibility for a load, or resume it on this phone (rescan).
create function public.lm_claim(p_code text, p_device uuid, p_name text,
                                p_override_soft boolean default false, p_takeover boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  m lm_loads; l loads; tkey text; last_t text; mismatch boolean; token text; held boolean;
  prev_device uuid; prev_name text; blocked text; kind text;
begin
  if p_device is null then raise exception 'No device id' using errcode = 'LM409'; end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then raise exception 'Confirm who you are first' using errcode = 'LM409'; end if;

  select * into m from lm_loads where claim_code = _lm_norm_code(p_code) for update;
  if not found then raise exception 'Code not recognised' using errcode = 'LM404'; end if;
  select * into l from loads where id = m.load_id;

  if l.check_status is distinct from 'confirmed' then
    raise exception '% has not been confirmed by the checker yet', l.load_nbr using errcode = 'LM409';
  end if;
  if m.status in ('completed', 'closed') then
    raise exception '% is already finished', l.load_nbr using errcode = 'LM409';
  end if;
  if l.ship_via is null then raise exception '% has no trucker yet', l.load_nbr using errcode = 'LM409'; end if;

  tkey := lm_trucker_key(l.ship_via);
  select ol.load_nbr into blocked
    from lm_loads o join loads ol on ol.id = o.load_id
   where o.trucker_key = tkey and o.status in ('collected', 'delivering') and o.load_id <> m.load_id limit 1;
  if blocked is not null then
    raise exception 'You still have % open. Finish it first, or ask the office.', blocked using errcode = 'LM409';
  end if;

  held := m.token_hash is not null;
  prev_device := m.claimed_device; prev_name := m.claimed_name;
  if held and prev_device is distinct from p_device and not p_takeover then
    raise exception 'Already held by % on another phone', coalesce(prev_name, 'someone') using errcode = 'LM411';
  end if;

  select last_trucker into last_t from lm_devices where device_id = p_device;
  mismatch := last_t is not null and last_t <> tkey;
  if mismatch and not p_override_soft then
    raise exception 'This phone last ran %, but this load is for %', last_t, tkey using errcode = 'LM410';
  end if;

  token := encode(extensions.gen_random_bytes(32), 'hex');
  update lm_loads
     set token_hash = _lm_hash(token), claimed_device = p_device, claimed_name = btrim(p_name), trucker_key = tkey,
         claimed_at = coalesce(claimed_at, now()),
         status = case when status = 'ready' then 'collected' else status end
   where load_id = m.load_id;
  perform _lm_snapshot(m.load_id);

  insert into lm_devices (device_id, last_trucker, last_claim_at) values (p_device, tkey, now())
  on conflict (device_id) do update set last_trucker = excluded.last_trucker, last_claim_at = excluded.last_claim_at;

  kind := case when held then 'rescan' else 'claim' end;
  perform _lm_event(m.load_id, kind, 'driver', p_device := p_device, p_payload := jsonb_build_object(
    'trucker_key', tkey, 'name', btrim(p_name), 'soft_mismatch', mismatch, 'previous_trucker', last_t,
    'previous_device', prev_device, 'previous_name', prev_name, 'took_over', (held and prev_device is distinct from p_device)));

  return jsonb_build_object('token', token, 'kind', kind, 'soft_mismatch', mismatch, 'data', _lm_load_json(m.load_id));
end $$;

-- The app's copy of the load, for drawing it and for working offline.
create function public.lm_my_load(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m lm_loads;
begin
  m := _lm_auth(p_token);
  return _lm_load_json(m.load_id);
end $$;

-- "Something is missing": tells the office before the truck leaves. Doesn't claim.
create function public.lm_report_shortage(p_code text, p_device uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare m lm_loads;
begin
  if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Say what is missing' using errcode = 'LM409'; end if;
  select * into m from lm_loads where claim_code = _lm_norm_code(p_code);
  if not found then raise exception 'Code not recognised' using errcode = 'LM404'; end if;
  update lm_loads set shortage_note = btrim(p_note) where load_id = m.load_id;
  perform _lm_event(m.load_id, 'shortage', 'driver', p_device := p_device, p_payload := jsonb_build_object('note', btrim(p_note)));
end $$;

-- ------------------------------------------------------------------
-- Staff functions (authenticated)
-- ------------------------------------------------------------------

-- Load sheet data. Issues the claim code if the load doesn't have one yet.
create function public.lm_sheet(p_load_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare code text; l loads; units numeric;
begin
  code := lm_ensure_load(p_load_id);     -- checks the role and that the checker has confirmed it
  select * into l from loads where id = p_load_id;
  select coalesce(sum(coalesce(cl.final_qty, sl.shipped_qty)), 0) into units
    from load_shipments ls
    join shipment_lines sl on sl.env = l.env and sl.shipment_nbr = ls.shipment_nbr
    left join check_lines cl on cl.load_id = l.id and cl.shipment_nbr = sl.shipment_nbr and cl.line_nbr = sl.line_nbr
   where ls.load_id = l.id and coalesce(cl.final_qty, sl.shipped_qty) > 0;
  return jsonb_build_object(
    'code', code, 'load_nbr', l.load_nbr, 'load_date', l.load_date, 'wave', l.wave, 'env', l.env,
    'ship_via', l.ship_via, 'trucker', (select description from ship_via_codes where ship_via = l.ship_via),
    'truck_type', l.truck_type, 'units', units,
    'stops', coalesce((
      select jsonb_agg(jsonb_build_object(
               'seq', r.seq, 'customer_id', r.customer_id, 'customer_name', r.customer_name, 'city', r.city, 'zone', r.zone,
               'shipments', (select coalesce(jsonb_agg(ls.shipment_nbr order by ls.shipment_nbr), '[]'::jsonb)
                               from load_shipments ls
                               join lateral (select * from _dispatch_shipments(l.env) x where x.shipment_nbr = ls.shipment_nbr) s on true
                              where ls.load_id = l.id and coalesce(s.customer_id, '?') = r.customer_id))
             order by r.seq)
        from _lm_stop_rows(p_load_id) r), '[]'::jsonb));
end $$;

-- Undo a mistaken claim so the driver can scan the right load. Only before any stop
-- has left 'pending'; after that the office aborts or closes the load instead.
create function public.lm_unassign(p_load_id bigint, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare m lm_loads;
begin
  if auth.uid() is null or not (dispatch_has_role('supervisor') or dispatch_has_role('manager')) then
    raise exception 'Only a supervisor or manager can unassign a load' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Say why it is being unassigned'; end if;
  select * into m from lm_loads where load_id = p_load_id for update;
  if not found or m.token_hash is null then raise exception 'That load is not claimed'; end if;
  if exists (select 1 from lm_stops where load_id = p_load_id and status <> 'pending') then
    raise exception 'Deliveries have already been recorded on this load. Abort or close it instead.';
  end if;

  delete from lm_stops where load_id = p_load_id;
  update lm_loads
     set token_hash = null, claimed_device = null, claimed_name = null, claimed_at = null, trucker_key = null,
         status = 'ready'
   where load_id = p_load_id;
  perform _lm_event(p_load_id, 'unassign', 'office', p_actor := dispatch_actor_name(), p_payload := jsonb_build_object(
    'reason', btrim(p_reason), 'previous_name', m.claimed_name, 'previous_device', m.claimed_device));
end $$;

-- ------------------------------------------------------------------
-- Grants
-- ------------------------------------------------------------------
revoke all on function public._lm_norm_code(text)                                 from public, anon, authenticated;
revoke all on function public._lm_hash(text)                                      from public, anon, authenticated;
revoke all on function public._lm_auth(text)                                      from public, anon, authenticated;
revoke all on function public._lm_stop_rows(bigint)                               from public, anon, authenticated;
revoke all on function public._lm_snapshot(bigint)                                from public, anon, authenticated;
revoke all on function public._lm_load_json(bigint)                               from public, anon, authenticated;
revoke all on function public.lm_peek(text, uuid)                                 from public;
revoke all on function public.lm_claim(text, uuid, text, boolean, boolean)        from public;
revoke all on function public.lm_my_load(text)                                    from public;
revoke all on function public.lm_report_shortage(text, uuid, text)                from public;
revoke all on function public.lm_sheet(bigint)                                    from public, anon;
revoke all on function public.lm_unassign(bigint, text)                           from public, anon;
grant execute on function public.lm_peek(text, uuid)                              to anon, authenticated;
grant execute on function public.lm_claim(text, uuid, text, boolean, boolean)     to anon, authenticated;
grant execute on function public.lm_my_load(text)                                 to anon, authenticated;
grant execute on function public.lm_report_shortage(text, uuid, text)             to anon, authenticated;
grant execute on function public.lm_sheet(bigint)                                 to authenticated;
grant execute on function public.lm_unassign(bigint, text)                        to authenticated;

-- ------------------------------------------------------------------
-- Rollback (by hand)
-- ------------------------------------------------------------------
-- drop function public.lm_unassign(bigint, text);
-- drop function public.lm_sheet(bigint);
-- drop function public.lm_report_shortage(text, uuid, text);
-- drop function public.lm_my_load(text);
-- drop function public.lm_claim(text, uuid, text, boolean, boolean);
-- drop function public.lm_peek(text, uuid);
-- drop function public._lm_load_json(bigint);
-- drop function public._lm_snapshot(bigint);
-- drop function public._lm_stop_rows(bigint);
-- drop function public._lm_auth(text);
-- drop function public._lm_hash(text);
-- drop function public._lm_norm_code(text);
