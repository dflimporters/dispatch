-- Dispatch loads: the batcher builds loads, the clerk confirms a trucker, and
-- the dispatch-acu edge function writes ShipVia + load number to Acumatica and
-- confirms the shipments.
--
-- Nobody writes these tables directly. Pages read them through RLS (any
-- dispatch role) and change them only through the dispatch_* functions
-- below, which check the caller's role and the load's status. The edge
-- function uses the service role for the writeback results.
--
-- env: 'test' rows pair with shipments_test (mirror of the Acumatica TEST
-- tenant), 'live' rows with shipments (production). Never mixed.

-- ------------------------------------------------------------------
-- Roles
-- ------------------------------------------------------------------
create table public.dispatch_roles (
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       text not null check (role in ('batcher', 'clerk')),
  granted_at timestamptz not null default now(),
  primary key (user_id, role)
);
alter table public.dispatch_roles enable row level security;
create policy dispatch_roles_read_own on public.dispatch_roles
  for select to authenticated using (user_id = auth.uid());

-- p_role null = any dispatch role.
create function public.dispatch_has_role(p_role text default null) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from dispatch_roles
                 where user_id = auth.uid() and (p_role is null or role = p_role));
$$;

create function public.dispatch_actor_name() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select full_name from profiles where id = auth.uid()),
                  (select email from auth.users where id = auth.uid()));
$$;

-- ------------------------------------------------------------------
-- TEST tenant mirror (filled by dispatch-acu, action sync_test)
-- ------------------------------------------------------------------
create table public.shipments_test (like public.shipments including all);
alter table public.shipments_test enable row level security;
create policy shipments_test_read on public.shipments_test
  for select to authenticated using (public.dispatch_has_role());

-- The env's shipments, one shape for both.
create function public._dispatch_shipments(p_env text) returns setof public.shipments
language sql stable security definer set search_path = public as $$
  select * from shipments where p_env = 'live'
  union all
  select * from shipments_test where p_env = 'test';
$$;

-- ------------------------------------------------------------------
-- Loads
-- ------------------------------------------------------------------
create table public.loads (
  id            bigint generated always as identity primary key,
  env           text not null check (env in ('live', 'test')),
  load_date     date not null,
  wave          text not null check (wave in ('AM', 'PM')),
  seq           int  not null,
  load_nbr      text not null,               -- L-MMDD-AM-NN, set by trigger
  truck_type    text,
  --   draft      batcher is building it
  --   ready      with the clerk
  --   confirmed  trucker locked in, not yet written
  --   writing    dispatch-acu is writing it now
  --   done       every shipment written and confirmed in Acumatica
  --   partial    written, but some shipments refused or failed
  status        text not null default 'draft'
                check (status in ('draft', 'ready', 'confirmed', 'writing', 'done', 'partial')),
  ship_via      text,
  contractor    text,
  notes         text,
  returned_note text,                        -- clerk's reason for sending it back
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  sent_by       uuid, sent_at      timestamptz,
  confirmed_by  uuid, confirmed_at timestamptz,
  applied_at    timestamptz,
  unique (env, load_date, wave, seq)
);
create index loads_env_date on public.loads (env, load_date);

-- Number = next free sequence for that env/date/wave. Only drafts can change
-- date or wave (enforced in the functions), so a number that reached
-- Acumatica never changes.
create function public.loads_number() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.wave is distinct from old.wave or new.load_date is distinct from old.load_date then
    perform pg_advisory_xact_lock(hashtext('loads:' || new.env || new.load_date::text || new.wave));
    select coalesce(max(seq), 0) + 1 into new.seq
      from public.loads
     where env = new.env and load_date = new.load_date and wave = new.wave and id is distinct from new.id;
    new.load_nbr := 'L-' || to_char(new.load_date, 'MMDD') || '-' || new.wave || '-' || lpad(new.seq::text, 2, '0');
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger loads_number before insert or update on public.loads
  for each row execute function public.loads_number();

-- A shipment is on at most one load per env.
create table public.load_shipments (
  env             text not null check (env in ('live', 'test')),
  shipment_nbr    text not null,
  load_id         bigint not null references public.loads(id) on delete cascade,
  added_by        uuid default auth.uid(),
  added_at        timestamptz not null default now(),
  ship_via_before text,                      -- snapshot at confirmation; writeback guard
  result          text check (result in ('applied', 'refused', 'failed')),
  result_detail   text,
  result_at       timestamptz,
  primary key (env, shipment_nbr)
);
create index load_shipments_load on public.load_shipments (load_id);

-- Append-only history. load_nbr is copied so deleted drafts still read well.
create table public.load_events (
  id         bigint generated always as identity primary key,
  load_id    bigint references public.loads(id) on delete set null,
  env        text not null,
  load_nbr   text,
  kind       text not null,  -- create, edit, move, send, pull_back, return, delete, call, confirm, unconfirm, writeback, unstick
  outcome    text,
  ship_via   text,
  contractor text,
  note       text,
  detail     jsonb,
  actor      uuid default auth.uid(),
  actor_name text,
  created_at timestamptz not null default now()
);
create index load_events_load on public.load_events (load_id);

alter table public.loads          enable row level security;
alter table public.load_shipments enable row level security;
alter table public.load_events    enable row level security;
create policy loads_read          on public.loads          for select to authenticated using (public.dispatch_has_role());
create policy load_shipments_read on public.load_shipments for select to authenticated using (public.dispatch_has_role());
create policy load_events_read    on public.load_events    for select to authenticated using (public.dispatch_has_role());

-- ------------------------------------------------------------------
-- Internal helpers
-- ------------------------------------------------------------------
create function public._dispatch_require(p_role text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if not dispatch_has_role(p_role) then
    raise exception 'Your account doesn''t have the % role', p_role using errcode = '42501';
  end if;
end $$;

create function public._dispatch_log(p_load public.loads, p_kind text, p_note text default null,
                                     p_detail jsonb default null, p_outcome text default null,
                                     p_ship_via text default null, p_contractor text default null) returns void
language sql security definer set search_path = public as $$
  insert into load_events (load_id, env, load_nbr, kind, outcome, ship_via, contractor, note, detail, actor_name)
  values (p_load.id, p_load.env, p_load.load_nbr, p_kind, p_outcome, p_ship_via, p_contractor, p_note, p_detail, dispatch_actor_name());
$$;

-- Lock a load and check it's in one of the allowed statuses.
create function public._dispatch_lock(p_id bigint, p_statuses text[]) returns public.loads
language plpgsql security definer set search_path = public as $$
declare l loads;
begin
  select * into l from loads where id = p_id for update;
  if not found then raise exception 'Load not found (it may have been deleted)'; end if;
  if not (l.status = any (p_statuses)) then
    raise exception '% is %, so it can''t be changed that way', l.load_nbr, l.status;
  end if;
  return l;
end $$;

-- Shipments that can go on a load: outbound, On Hold/Open, no real ShipVia
-- yet (empty or an old BATCH placeholder), and not already on a load.
create function public._dispatch_check_free(p_env text, p_nbrs text[]) returns void
language plpgsql stable security definer set search_path = public as $$
declare bad text; taken text;
begin
  select string_agg(n, ', ') into bad
    from unnest(p_nbrs) n
   where not exists (
     select 1 from _dispatch_shipments(p_env) s
      where s.shipment_nbr = n and s.operation = 'Issue' and coalesce(s.order_type, '') <> 'RC'
        and s.status in ('On Hold', 'Open')
        and (s.ship_via is null or s.ship_via ilike 'BATCH%'));
  if bad is not null then
    raise exception 'Can''t load these (not open, already have a Ship Via, or not found): %', bad;
  end if;
  select string_agg(ls.shipment_nbr || ' (' || l.load_nbr || ')', ', ') into taken
    from load_shipments ls join loads l on l.id = ls.load_id
   where ls.env = p_env and ls.shipment_nbr = any (p_nbrs);
  if taken is not null then raise exception 'Already on a load: %', taken; end if;
end $$;

-- ------------------------------------------------------------------
-- Page API
-- ------------------------------------------------------------------
create function public.dispatch_me() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'user_id', auth.uid(),
    'name',    dispatch_actor_name(),
    'roles',   coalesce((select jsonb_agg(role order by role) from dispatch_roles where user_id = auth.uid()), '[]'::jsonb));
$$;

-- Batcher --------------------------------------------------------------

create function public.dispatch_create_load(p_env text, p_date date, p_wave text,
                                            p_truck_type text default null,
                                            p_shipments text[] default '{}') returns bigint
language plpgsql security definer set search_path = public as $$
declare l loads;
begin
  perform _dispatch_require('batcher');
  p_shipments := coalesce(p_shipments, '{}');
  perform _dispatch_check_free(p_env, p_shipments);
  insert into loads (env, load_date, wave, seq, load_nbr, truck_type)
  values (p_env, p_date, p_wave, 0, '', p_truck_type)
  returning * into l;
  insert into load_shipments (env, shipment_nbr, load_id)
  select p_env, n, l.id from unnest(p_shipments) n;
  perform _dispatch_log(l, 'create', null, jsonb_build_object('shipments', p_shipments, 'truck_type', p_truck_type));
  return l.id;
end $$;

create function public.dispatch_update_load(p_id bigint, p_wave text, p_truck_type text, p_notes text) returns void
language plpgsql security definer set search_path = public as $$
declare l loads; n loads;
begin
  perform _dispatch_require('batcher');
  l := _dispatch_lock(p_id, array['draft']);
  update loads set wave = p_wave, truck_type = p_truck_type, notes = p_notes
   where id = p_id returning * into n;
  perform _dispatch_log(n, 'edit', null, jsonb_build_object(
    'wave', jsonb_build_array(l.wave, n.wave), 'truck_type', jsonb_build_array(l.truck_type, n.truck_type),
    'old_nbr', l.load_nbr));
end $$;

-- Move shipments to a draft load (p_to), or back to the pool (p_to null).
-- From a draft: anything. From a written load: only refused/failed ones, so
-- the batcher can re-home what Acumatica wouldn't take.
create function public.dispatch_move_shipments(p_env text, p_shipments text[], p_to bigint) returns void
language plpgsql security definer set search_path = public as $$
declare t loads; src record; bad text; fresh text[];
begin
  perform _dispatch_require('batcher');
  if p_to is not null then
    t := _dispatch_lock(p_to, array['draft']);
    if t.env <> p_env then raise exception 'Wrong environment'; end if;
  end if;

  select string_agg(ls.shipment_nbr || ' (' || l.load_nbr || ', ' || l.status || ')', ', ') into bad
    from load_shipments ls join loads l on l.id = ls.load_id
   where ls.env = p_env and ls.shipment_nbr = any (p_shipments)
     and not (l.status = 'draft'
              or (l.status in ('confirmed', 'partial', 'done') and coalesce(ls.result, '') in ('refused', 'failed')));
  if bad is not null then raise exception 'Can''t move these: %', bad; end if;

  select array_agg(n) into fresh from unnest(p_shipments) n
   where not exists (select 1 from load_shipments where env = p_env and shipment_nbr = n);
  if fresh is not null then
    if p_to is null then raise exception 'Not on a load: %', array_to_string(fresh, ', '); end if;
    perform _dispatch_check_free(p_env, fresh);
  end if;

  for src in
    select l.*, array_agg(ls.shipment_nbr) nbrs
      from load_shipments ls join loads l on l.id = ls.load_id
     where ls.env = p_env and ls.shipment_nbr = any (p_shipments) and l.id is distinct from p_to
     group by l.id
  loop
    delete from load_shipments where env = p_env and load_id = src.id and shipment_nbr = any (src.nbrs);
    insert into load_events (load_id, env, load_nbr, kind, note, detail, actor_name)
    values (src.id, p_env, src.load_nbr, 'move',
            case when p_to is null then 'Removed from load' else 'Moved to ' || t.load_nbr end,
            jsonb_build_object('shipments', src.nbrs, 'to', t.load_nbr), dispatch_actor_name());
    -- A partial load whose leftovers have all been re-homed is now done.
    if src.status = 'partial' and not exists (
         select 1 from load_shipments where load_id = src.id and result is distinct from 'applied') then
      update loads set status = 'done', applied_at = coalesce(applied_at, now()) where id = src.id;
    end if;
  end loop;

  if p_to is not null then
    insert into load_shipments (env, shipment_nbr, load_id)
    select p_env, n, p_to from unnest(p_shipments) n
    on conflict (env, shipment_nbr) do nothing;
    perform _dispatch_log(t, 'move', 'Added shipments', jsonb_build_object('shipments', p_shipments));
  end if;
end $$;

create function public.dispatch_delete_load(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare l loads;
begin
  perform _dispatch_require('batcher');
  l := _dispatch_lock(p_id, array['draft']);
  perform _dispatch_log(l, 'delete', null, jsonb_build_object(
    'shipments', (select coalesce(jsonb_agg(shipment_nbr), '[]') from load_shipments where load_id = p_id)));
  delete from loads where id = p_id;
end $$;

-- Status changes:
--   send       batcher  draft -> ready
--   pull_back  batcher  ready -> draft
--   return     clerk    ready -> draft (p_note required: why)
--   unconfirm  clerk    confirmed, nothing written yet -> ready
--   unstick    clerk    writing for over 5 minutes (writeback died) -> partial
create function public.dispatch_load_action(p_id bigint, p_action text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare l loads;
begin
  if p_action = 'send' then
    perform _dispatch_require('batcher');
    l := _dispatch_lock(p_id, array['draft']);
    if not exists (select 1 from load_shipments where load_id = p_id) then raise exception '% has no shipments', l.load_nbr; end if;
    if l.truck_type is null then raise exception 'Pick a truck type for % first', l.load_nbr; end if;
    update loads set status = 'ready', sent_by = auth.uid(), sent_at = now(), returned_note = null where id = p_id;
  elsif p_action = 'pull_back' then
    perform _dispatch_require('batcher');
    l := _dispatch_lock(p_id, array['ready']);
    update loads set status = 'draft' where id = p_id;
  elsif p_action = 'return' then
    perform _dispatch_require('clerk');
    l := _dispatch_lock(p_id, array['ready']);
    if coalesce(trim(p_note), '') = '' then raise exception 'Say why it''s going back to the batcher'; end if;
    update loads set status = 'draft', returned_note = trim(p_note) where id = p_id;
  elsif p_action = 'unconfirm' then
    perform _dispatch_require('clerk');
    l := _dispatch_lock(p_id, array['confirmed']);
    if exists (select 1 from load_shipments where load_id = p_id and result is not null) then
      raise exception '% has already been partly written to Acumatica', l.load_nbr;
    end if;
    update loads set status = 'ready', confirmed_by = null, confirmed_at = null where id = p_id;
    update load_shipments set ship_via_before = null where load_id = p_id;
  elsif p_action = 'unstick' then
    perform _dispatch_require('clerk');
    l := _dispatch_lock(p_id, array['writing']);
    if l.updated_at > now() - interval '5 minutes' then raise exception '% is still being written; wait a few minutes', l.load_nbr; end if;
    update loads set status = 'partial' where id = p_id;
  else
    raise exception 'Unknown action %', p_action;
  end if;
  perform _dispatch_log(l, p_action, p_note);
end $$;

-- Clerk ----------------------------------------------------------------

create function public.dispatch_log_call(p_id bigint, p_outcome text, p_ship_via text,
                                         p_contractor text, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare l loads;
begin
  perform _dispatch_require('clerk');
  l := _dispatch_lock(p_id, array['ready']);
  perform _dispatch_log(l, 'call', nullif(trim(p_note), ''), null, p_outcome,
                        nullif(trim(p_ship_via), ''), nullif(trim(p_contractor), ''));
end $$;

-- Lock in the trucker. The writeback itself is dispatch-acu, called next by
-- the page. Snapshots each shipment's current ShipVia as the guard value.
create function public.dispatch_confirm_load(p_id bigint, p_ship_via text, p_contractor text, p_notes text) returns void
language plpgsql security definer set search_path = public as $$
declare l loads; n loads; bad text;
begin
  perform _dispatch_require('clerk');
  l := _dispatch_lock(p_id, array['ready']);
  p_ship_via := nullif(trim(p_ship_via), '');
  if p_ship_via is null then raise exception 'Pick the trucker''s Ship Via'; end if;
  if p_ship_via ilike 'BATCH%' then raise exception '% is a placeholder, not a trucker', p_ship_via; end if;
  if not exists (select 1 from ship_via_codes where ship_via = p_ship_via) then
    raise exception '% isn''t a Ship Via code in Acumatica', p_ship_via;
  end if;

  select string_agg(ls.shipment_nbr || coalesce(' (' || s.status || ')', ' (not found)'), ', ') into bad
    from load_shipments ls
    left join _dispatch_shipments(l.env) s on s.shipment_nbr = ls.shipment_nbr
   where ls.load_id = p_id
     and (s.shipment_nbr is null or s.status not in ('On Hold', 'Open'));
  if bad is not null then raise exception 'Send it back to the batcher; these aren''t open any more: %', bad; end if;

  update load_shipments ls set ship_via_before = s.ship_via
    from _dispatch_shipments(l.env) s
   where ls.load_id = p_id and s.shipment_nbr = ls.shipment_nbr;

  update loads set status = 'confirmed', ship_via = p_ship_via, contractor = nullif(trim(p_contractor), ''),
                   notes = nullif(trim(p_notes), ''), confirmed_by = auth.uid(), confirmed_at = now()
   where id = p_id returning * into n;
  perform _dispatch_log(n, 'confirm', n.notes,
    jsonb_build_object('shipments', (select jsonb_agg(shipment_nbr) from load_shipments where load_id = p_id)),
    null, n.ship_via, n.contractor);
end $$;

-- ------------------------------------------------------------------
-- Grants: signed-in users only. Helpers aren't callable from the API.
-- RLS already blocks writes (no write policies); revoking says so outright.
-- ------------------------------------------------------------------
revoke insert, update, delete, truncate on public.dispatch_roles, public.shipments_test,
  public.loads, public.load_shipments, public.load_events from anon, authenticated;
revoke all on public.dispatch_roles, public.shipments_test, public.loads,
  public.load_shipments, public.load_events from anon;

revoke all on function public.dispatch_has_role(text)                     from public, anon;
revoke all on function public.dispatch_actor_name()                       from public, anon, authenticated;
revoke all on function public._dispatch_shipments(text)                   from public, anon, authenticated;
revoke all on function public._dispatch_require(text)                     from public, anon, authenticated;
revoke all on function public._dispatch_log(public.loads, text, text, jsonb, text, text, text) from public, anon, authenticated;
revoke all on function public._dispatch_lock(bigint, text[])              from public, anon, authenticated;
revoke all on function public._dispatch_check_free(text, text[])          from public, anon, authenticated;
revoke all on function public.dispatch_me()                               from public, anon;
revoke all on function public.dispatch_create_load(text, date, text, text, text[]) from public, anon;
revoke all on function public.dispatch_update_load(bigint, text, text, text)       from public, anon;
revoke all on function public.dispatch_move_shipments(text, text[], bigint)        from public, anon;
revoke all on function public.dispatch_delete_load(bigint)                         from public, anon;
revoke all on function public.dispatch_load_action(bigint, text, text)             from public, anon;
revoke all on function public.dispatch_log_call(bigint, text, text, text, text)    from public, anon;
revoke all on function public.dispatch_confirm_load(bigint, text, text, text)      from public, anon;

grant execute on function public.dispatch_has_role(text)                          to authenticated;
grant execute on function public.dispatch_me()                                    to authenticated;
grant execute on function public.dispatch_create_load(text, date, text, text, text[]) to authenticated;
grant execute on function public.dispatch_update_load(bigint, text, text, text)   to authenticated;
grant execute on function public.dispatch_move_shipments(text, text[], bigint)    to authenticated;
grant execute on function public.dispatch_delete_load(bigint)                     to authenticated;
grant execute on function public.dispatch_load_action(bigint, text, text)         to authenticated;
grant execute on function public.dispatch_log_call(bigint, text, text, text, text) to authenticated;
grant execute on function public.dispatch_confirm_load(bigint, text, text, text)  to authenticated;
