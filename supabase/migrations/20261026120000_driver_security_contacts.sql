-- Driver app + load sheet round (Joel, 2026-10-26). Applied to the live project (Supabase hzagwndglwhcepsirafi) on 2026-10-26.
--
-- 1. Security return check, independent of the returns clerk. New role 'security',
--    lm_security_check_items (a short checklist), lm_security_checks (one row per check, many
--    allowed per load), lm_security_lookup / lm_security_submit. Security counts every line of
--    the load's return sheet against what physically came back; any difference flags the load.
--    It never touches lm_returns, so the clerk's receiving is unaffected.
--    A load cannot be closed until its latest security check is clear (lm_close_load below).
-- 2. The driver app can show the load's QR (lm_loads.claim_code is added to the driver's load
--    JSON; the driver already holds the load token, and the sheet is theirs).
-- 3. Quick contact per stop: lm_sales_contacts (editable on contacts.html) and
--    _lm_stop_contacts(). Sales rep = the shipments' salesperson_code -> reps (name, phone) with
--    an override table; sales support = customer, then sales area, then a default row.
--
-- Rollback is at the bottom.

-- ------------------------------------------------------------------
-- 4. Sales contacts
-- ------------------------------------------------------------------
create table public.lm_sales_contacts (
  id          bigint generated always as identity primary key,
  kind        text not null check (kind in ('rep', 'support')),
  scope       text not null check (scope in ('customer', 'rep', 'area', 'default')),
  key         text not null default '',     -- customer id, rep code (reps.salesperson_id), sales area, or '' for default
  name        text not null,
  phone       text not null,                -- WhatsApp is the same number
  updated_by  text,
  updated_at  timestamptz not null default now(),
  unique (kind, scope, key),
  check ((kind = 'rep' and scope in ('customer', 'rep')) or (kind = 'support' and scope in ('customer', 'area', 'default'))),
  check ((scope = 'default') = (key = ''))
);
alter table public.lm_sales_contacts enable row level security;
revoke all on public.lm_sales_contacts from anon, authenticated;

-- The two contacts for one stop: [{kind, label, name, phone}]. phone is null when we know who
-- but not the number yet.
create function public._lm_stop_contacts(p_stop_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  st lm_stops; v_env text; v_area text; v_code text; v_out jsonb := '[]'::jsonb;
  v_name text; v_phone text; o lm_sales_contacts;
begin
  select * into st from lm_stops where id = p_stop_id;
  if not found then return v_out; end if;
  select l.env into v_env from loads l where l.id = st.load_id;
  select nullif(btrim(c.sales_area), '') into v_area from customers c where c.customer_id = st.customer_id limit 1;
  if lower(coalesce(v_area, '')) = 'unassigned' then v_area := null; end if;
  select s.salesperson_code into v_code
    from _dispatch_shipments(v_env) s
    join lm_stop_invoices i on i.shipment_nbr = s.shipment_nbr and i.stop_id = st.id
   where nullif(btrim(s.salesperson_code), '') is not null
   group by s.salesperson_code order by count(*) desc, s.salesperson_code limit 1;

  -- sales rep
  select * into o from lm_sales_contacts where kind = 'rep' and scope = 'customer' and key = st.customer_id;
  if not found and v_code is not null then
    select * into o from lm_sales_contacts where kind = 'rep' and scope = 'rep' and key = v_code;
  end if;
  if found then v_name := o.name; v_phone := o.phone;
  elsif v_code is not null then
    select r.name, nullif(btrim(r.phone), '') into v_name, v_phone from reps r where r.salesperson_id = v_code limit 1;
    if v_name is null then select max(s.salesperson_name) into v_name from shipments s where s.salesperson_code = v_code; end if;
  else v_name := null; v_phone := null; end if;
  if v_name is not null or v_phone is not null then
    v_out := v_out || jsonb_build_array(jsonb_build_object('kind', 'rep', 'label', 'Sales rep', 'name', v_name, 'phone', v_phone));
  end if;

  -- sales support
  o := null;
  select * into o from lm_sales_contacts where kind = 'support' and scope = 'customer' and key = st.customer_id;
  if not found and v_area is not null then
    select * into o from lm_sales_contacts where kind = 'support' and scope = 'area' and lower(key) = lower(v_area);
  end if;
  if not found then select * into o from lm_sales_contacts where kind = 'support' and scope = 'default'; end if;
  if found then
    v_out := v_out || jsonb_build_array(jsonb_build_object('kind', 'support', 'label', 'Sales support', 'name', o.name, 'phone', o.phone));
  end if;
  return v_out;
end $$;
revoke all on function public._lm_stop_contacts(bigint) from public, anon, authenticated;

-- ------------------------------------------------------------------
-- 3 + 4. The load as the driver app sees it (replaces the lm_returns_flow version):
--        adds load.claim_code and stops[].contacts
-- ------------------------------------------------------------------
create or replace function public._lm_load_json(p_load_id bigint) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'load', jsonb_build_object('id', l.id, 'load_nbr', l.load_nbr, 'load_date', l.load_date, 'ship_via', l.ship_via,
              'trucker', coalesce(sv.description, l.ship_via), 'truck_type', l.truck_type, 'status', m.status,
              'claimed_name', m.claimed_name, 'delivering_at', m.delivering_at, 'completed_at', m.completed_at,
              'aborted_at', m.aborted_at, 'abort_reason', m.abort_reason, 'abort_note', m.abort_note,
              'claim_code', m.claim_code),
    'stops', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', st.id, 'customer_id', st.customer_id, 'customer_name', st.customer_name, 'address', st.address,
          'city', st.city, 'phone', st.phone, 'zone', st.zone, 'note', st.delivery_note,
          'seq_suggested', st.seq_suggested, 'seq', st.seq_final, 'status', st.status,
          'on_the_way_at', st.on_the_way_at, 'arrived_at', st.arrived_at, 'completed_at', st.completed_at,
          'receiver_name', st.receiver_name, 'fail_reason', st.fail_reason, 'fail_note', st.fail_note,
          'contacts', _lm_stop_contacts(st.id),
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

-- Admin screen (contacts.html): supervisor or manager.
create function public.lm_contacts_list() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not (dispatch_has_role('supervisor') or dispatch_has_role('manager')) then
    raise exception 'Only a supervisor or manager can edit contacts' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'contacts', coalesce((select jsonb_agg(to_jsonb(c) order by c.kind, c.scope, c.key) from lm_sales_contacts c), '[]'::jsonb),
    'reps', coalesce((select jsonb_agg(jsonb_build_object('code', r.salesperson_id, 'name', r.name, 'phone', nullif(btrim(r.phone), ''),
                                                          'area', r.area) order by r.name)
                        from reps r where r.active and r.salesperson_id is not null and r.role in ('rep', 'rep_management', 'manager', 'management')), '[]'::jsonb),
    'areas', coalesce((select jsonb_agg(a order by a) from (select distinct btrim(sales_area) a from customers
                         where nullif(btrim(sales_area), '') is not null and lower(btrim(sales_area)) <> 'unassigned') x), '[]'::jsonb));
end $$;

create function public.lm_contact_save(p_kind text, p_scope text, p_key text, p_name text, p_phone text) returns void
language plpgsql security definer set search_path = public as $$
declare k text := btrim(coalesce(p_key, ''));
begin
  if auth.uid() is null or not (dispatch_has_role('supervisor') or dispatch_has_role('manager')) then
    raise exception 'Only a supervisor or manager can edit contacts' using errcode = '42501';
  end if;
  if length(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g')) < 7 then raise exception 'Enter a phone number'; end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then raise exception 'Enter a name'; end if;
  if p_scope = 'default' then k := ''; end if;
  insert into lm_sales_contacts (kind, scope, key, name, phone, updated_by, updated_at)
  values (p_kind, p_scope, k, btrim(p_name), btrim(p_phone), dispatch_actor_name(), now())
  on conflict (kind, scope, key) do update set name = excluded.name, phone = excluded.phone,
        updated_by = excluded.updated_by, updated_at = now();
end $$;

create function public.lm_contact_delete(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not (dispatch_has_role('supervisor') or dispatch_has_role('manager')) then
    raise exception 'Only a supervisor or manager can edit contacts' using errcode = '42501';
  end if;
  delete from lm_sales_contacts where id = p_id;
end $$;

revoke all on function public.lm_contacts_list() from public, anon;
revoke all on function public.lm_contact_save(text, text, text, text, text) from public, anon;
revoke all on function public.lm_contact_delete(bigint) from public, anon;
grant execute on function public.lm_contacts_list() to authenticated;
grant execute on function public.lm_contact_save(text, text, text, text, text) to authenticated;
grant execute on function public.lm_contact_delete(bigint) to authenticated;

-- ------------------------------------------------------------------
-- 2. Security return check
-- ------------------------------------------------------------------
alter table public.dispatch_roles drop constraint dispatch_roles_role_check;
alter table public.dispatch_roles add constraint dispatch_roles_role_check
  check (role in ('batcher', 'clerk', 'picker', 'checker', 'supervisor', 'manager', 'security'));
alter table public.dispatch_role_invites drop constraint dispatch_role_invites_role_check;
alter table public.dispatch_role_invites add constraint dispatch_role_invites_role_check
  check (role in ('batcher', 'clerk', 'picker', 'checker', 'supervisor', 'manager', 'security'));

create table public.lm_security_check_items (
  code   text primary key,
  label  text not null,
  active boolean not null default true,
  sort   smallint not null default 0
);
-- Starter list: review the wording.
insert into public.lm_security_check_items (code, label, sort) values
  ('driver_ok',      'The person bringing the truck back is the driver who collected the load', 10),
  ('truck_searched', 'Truck and cab checked: nothing on board that is not on the return sheet', 20);

create table public.lm_security_checks (
  id          bigint generated always as identity primary key,
  load_id     bigint not null references public.loads(id) on delete cascade,
  result      text not null check (result in ('clear', 'flagged')),
  items       jsonb not null default '{}'::jsonb,    -- { item code: true | false }
  counts      jsonb not null default '[]'::jsonb,    -- [{ line_id, expected, counted }], one per return-sheet line
  note        text,
  checked_by  text,
  checked_by_id uuid,
  checked_at  timestamptz not null default now()
);
create index lm_security_checks_load on public.lm_security_checks (load_id, checked_at desc);
alter table public.lm_security_checks enable row level security;
alter table public.lm_security_check_items enable row level security;
create policy lm_security_checks_read on public.lm_security_checks for select to authenticated using (public.dispatch_has_role());
create policy lm_security_items_read on public.lm_security_check_items for select to authenticated using (public.dispatch_has_role());
revoke all on public.lm_security_checks, public.lm_security_check_items from anon;
revoke insert, update, delete, truncate on public.lm_security_checks, public.lm_security_check_items from authenticated;

create function public._lm_security_ok() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (select 1 from dispatch_roles
          where user_id = auth.uid() and role in ('security', 'supervisor', 'manager'));
$$;
revoke all on function public._lm_security_ok() from public, anon, authenticated;

-- The load behind a scanned QR (or typed code), its return sheet, and earlier checks.
create function public.lm_security_lookup(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m lm_loads; l loads; hb jsonb; open_stops int;
begin
  if not _lm_security_ok() then raise exception 'Only security, a supervisor or a manager can do this' using errcode = '42501'; end if;
  select * into m from lm_loads where claim_code = _lm_norm_code(p_code);
  if not found then raise exception 'That code is not recognised' using errcode = 'LM404'; end if;
  select * into l from loads where id = m.load_id;
  select count(*) into open_stops from lm_stops where load_id = m.load_id and status in ('pending', 'on_the_way', 'arrived');
  select coalesce(jsonb_agg(jsonb_build_object('customer', coalesce(s.customer_name, s.customer_id), 'status', s.status, 'why', s.fail_note,
            'lines', x.lines) order by s.seq_final), '[]'::jsonb) into hb
    from lm_returns r
    join lm_stops s on s.id = r.stop_id
    join lateral (select jsonb_agg(jsonb_build_object('id', rl.id, 'description', coalesce(rl.description, rl.inventory_id), 'uom', rl.uom,
                         'shipment_nbr', rl.shipment_nbr, 'qty', rl.qty, 'why', coalesce(rl.note, rc.label)) order by rl.shipment_nbr, rl.line_nbr) lines
                    from lm_return_lines rl left join lm_reason_codes rc on rc.code = rl.reason_code
                   where rl.return_id = r.id) x on x.lines is not null
   where r.load_id = m.load_id;
  return jsonb_build_object(
    'load', jsonb_build_object('id', l.id, 'load_nbr', l.load_nbr, 'load_date', l.load_date, 'ship_via', l.ship_via,
              'trucker', (select description from ship_via_codes where ship_via = l.ship_via), 'truck_type', l.truck_type,
              'status', m.status, 'claimed_name', m.claimed_name, 'claimed_phone', m.claimed_phone,
              'aborted_at', m.aborted_at, 'open_stops', open_stops),
    'handback', hb,
    'items', coalesce((select jsonb_agg(jsonb_build_object('code', i.code, 'label', i.label) order by i.sort) from lm_security_check_items i where i.active), '[]'::jsonb),
    'checks', coalesce((select jsonb_agg(jsonb_build_object('result', c.result, 'items', c.items, 'counts', c.counts, 'note', c.note, 'checked_by', c.checked_by, 'checked_at', c.checked_at)
                                         order by c.checked_at desc)
                          from lm_security_checks c where c.load_id = l.id), '[]'::jsonb));
end $$;

-- p_counts: { "<return line id>": counted qty } for every line of the load's return sheet.
-- The result is worked out here: clear only if every count equals the sheet and every check is ticked.
-- Otherwise it is flagged, and a note is required.
create function public.lm_security_submit(p_load_id bigint, p_counts jsonb, p_items jsonb, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  n text := nullif(btrim(coalesce(p_note, '')), ''); new_id bigint; res text; mism int := 0; arr jsonb := '[]'::jsonb;
  it jsonb := case when jsonb_typeof(p_items) = 'object' then p_items else '{}'::jsonb end;
  cnt jsonb := case when jsonb_typeof(p_counts) = 'object' then p_counts else '{}'::jsonb end;
  rl record; c numeric;
begin
  if not _lm_security_ok() then raise exception 'Only security, a supervisor or a manager can do this' using errcode = '42501'; end if;
  if not exists (select 1 from lm_loads where load_id = p_load_id) then raise exception 'That load has no last-mile record'; end if;
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

revoke all on function public.lm_security_lookup(text) from public, anon;
revoke all on function public.lm_security_submit(bigint, jsonb, jsonb, text) from public, anon;
grant execute on function public.lm_security_lookup(text) to authenticated;
grant execute on function public.lm_security_submit(bigint, jsonb, jsonb, text) to authenticated;

-- ------------------------------------------------------------------
-- Closing a load now needs a clear security check (replaces the lm_returns_flow version).
-- LM412 = security has not cleared it.
-- ------------------------------------------------------------------
create or replace function public.lm_close_load(p_load_id bigint, p_note text default null, p_force boolean default false) returns jsonb
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
  if coalesce((select c.result from lm_security_checks c where c.load_id = p_load_id order by c.checked_at desc, c.id desc limit 1), '') <> 'clear' then
    raise exception 'Security has not cleared this load yet. The truck must be checked against the return sheet first.' using errcode = 'LM412';
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

-- ------------------------------------------------------------------
-- Rollback (by hand)
-- ------------------------------------------------------------------
-- drop function public.lm_security_submit(bigint, jsonb, jsonb, text); -- and re-run lm_close_load from 20261023020000_lm_returns_flow.sql
-- drop function public.lm_security_lookup(text);
-- drop function public._lm_security_ok(); drop table public.lm_security_checks, public.lm_security_check_items;
-- (restore the two role check constraints without 'security' after deleting any security role rows)
-- drop function public.lm_contact_delete(bigint); drop function public.lm_contact_save(text,text,text,text,text);
-- drop function public.lm_contacts_list(); drop table public.lm_sales_contacts;
-- re-run _lm_load_json from 20261023020000_lm_returns_flow.sql; drop function public._lm_stop_contacts(bigint);
