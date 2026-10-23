-- OMS last mile, step 1: data model and append-only events (Joel, 2026-10-22).
-- Applied to the live project (Supabase hzagwndglwhcepsirafi) on 2026-10-22, after a rolled-back dry run.
--
-- Scope (Phase 1 MVP of the DFL OMS design doc): what the driver app and Control
-- Tower need to store. This migration only ADDS new lm_* objects. It does not alter
-- loads, load_shipments, shipments, policies or any existing function.
--
-- How it fits
--   * A load becomes claimable once the checker has confirmed it
--     (loads.check_status = 'confirmed'). lm_ensure_load() gives it a claim code,
--     printed as a QR on the load sheet with the same code in text as the fallback.
--   * Drivers have no accounts. The driver app calls security-definer functions as
--     `anon` with a per-load secret; only a sha256 of that secret is stored
--     (lm_loads.token_hash). Those functions arrive in step 2. They are NOT callable
--     through Supabase anonymous sign-in, which would put drivers in the
--     `authenticated` role of a project shared with the sales portal.
--   * Every lm_* table is closed to anon and authenticated except staff reads.
--     Writes happen only inside security-definer functions.
--   * lm_events is the audit trail: append-only, one row per button press, idempotent
--     on event_uuid (made on the phone) so an offline queue can be replayed safely.
--     The current state (lm_loads.status, lm_stops.status, ...) is updated by the
--     same function in the same transaction as the event.
--   * Stops, invoices and lines are copied from the load when it is claimed (step 2),
--     so later Acumatica changes don't change the driver's checklist.
--   * A stop is one customer. A shipment is the invoice unit for now; invoice_nbr
--     stays empty until it is read from Acumatica.
--   * env (live/test) comes from loads; none of these tables repeat it.
--
-- Deleting a load (the auto-load sync only deletes loads nobody has started checking,
-- so a confirmed load is never deleted) removes its lm_loads / stops / lines / returns.
-- lm_events and lm_files keep their rows with load_id set null, so the audit and
-- the photos survive.
--
-- Rollback is at the bottom.

-- ------------------------------------------------------------------
-- Reason codes (editable later in Admin)
-- ------------------------------------------------------------------
create table public.lm_reason_codes (
  code       text primary key,
  label      text not null,
  cause      text not null check (cause in ('customer', 'internal', 'damaged')),
  applies_to text not null check (applies_to in ('line', 'stop', 'load', 'both')),   -- both = line and stop
  active     boolean not null default true,
  sort       smallint not null default 0
);

-- Starter list: review the wording. 'internal' feeds pick-error reporting.
insert into public.lm_reason_codes (code, label, cause, applies_to, sort) values
  ('customer_refused',  'Customer refused it',               'customer', 'both', 10),
  ('too_expensive',     'Price too high for the customer',   'customer', 'line', 20),
  ('not_ordered',       'Customer says not ordered',         'customer', 'line', 30),
  ('short_dated',       'Short dated, customer rejected',    'customer', 'line', 40),
  ('wrong_item',        'Wrong item sent',                   'internal', 'line', 50),
  ('short_picked',      'Not on the truck (short picked)',   'internal', 'line', 60),
  ('damaged',           'Damaged',                           'damaged',  'line', 70),
  ('customer_closed',   'Customer closed',                   'customer', 'stop', 110),
  ('no_one_to_receive', 'Nobody there to receive',           'customer', 'stop', 120),
  ('no_access',         'No access to the site',             'customer', 'stop', 130),
  ('breakdown',         'Truck breakdown',                   'internal', 'load', 210),
  ('accident',          'Accident',                          'internal', 'load', 220),
  ('security',          'Security concern',                  'internal', 'load', 230),
  ('weather',           'Weather or road conditions',        'internal', 'load', 240),
  ('other',             'Other (say why in the note)',       'internal', 'both', 900);

-- ------------------------------------------------------------------
-- Per-load state (one row per claimable load)
-- ------------------------------------------------------------------
create table public.lm_loads (
  load_id       bigint primary key references public.loads(id) on delete cascade,
  claim_code    text not null unique check (claim_code ~ '^[0-9A-HJKMNP-TV-Z]{8}$'),
  --   ready       checker confirmed, waiting for the driver's scan
  --   collected   driver scanned and took responsibility
  --   delivering  first "On the way" pressed
  --   completed   every stop resolved (delivered, partial or failed)
  --   closed      returns received at the warehouse (Phase 2 sets this; office can close in Phase 1)
  status        text not null default 'ready'
                check (status in ('ready', 'collected', 'delivering', 'completed', 'closed')),
  trucker_key   text,           -- lm_trucker_key(loads.ship_via) when claimed
  claimed_at    timestamptz,
  claimed_device uuid,
  claimed_name  text,           -- the name the driver confirmed on the review screen
  token_hash    text,           -- sha256 hex of the load-scoped secret; null = nobody holds the load
  shortage_note text,           -- "Something is missing" reported at the scan
  delivering_at timestamptz,
  completed_at  timestamptz,
  closed_at     timestamptz,
  closed_by     text,
  aborted_at    timestamptz,    -- driver aborted the rest of the load
  abort_reason  text references public.lm_reason_codes(code),
  abort_note    text,
  created_at    timestamptz not null default now()
);
create unique index lm_loads_token on public.lm_loads (token_hash) where token_hash is not null;
create index lm_loads_trucker on public.lm_loads (trucker_key) where status in ('collected', 'delivering');

-- ------------------------------------------------------------------
-- Stops: one per customer on the load
-- ------------------------------------------------------------------
create table public.lm_stops (
  id             bigint generated always as identity primary key,
  load_id        bigint not null references public.loads(id) on delete cascade,
  customer_id    text not null,
  customer_name  text,
  address        text,            -- snapshot from customers when claimed
  city           text,
  phone          text,
  zone           text,
  delivery_note  text,
  seq_suggested  int not null,    -- what the app proposed
  seq_final      int not null,    -- what the driver saved
  --   pending -> on_the_way -> arrived -> delivered | partial | failed
  status         text not null default 'pending'
                 check (status in ('pending', 'on_the_way', 'arrived', 'delivered', 'partial', 'failed')),
  on_the_way_at  timestamptz,
  arrived_at     timestamptz,
  completed_at   timestamptz,
  receiver_name  text,
  fail_reason    text references public.lm_reason_codes(code),
  fail_note      text,
  unique (load_id, customer_id)
);
create index lm_stops_load on public.lm_stops (load_id, seq_final);

-- Shipments (invoices) under a stop.
create table public.lm_stop_invoices (
  id            bigint generated always as identity primary key,
  stop_id       bigint not null references public.lm_stops(id) on delete cascade,
  shipment_nbr  text not null,
  invoice_nbr   text,
  unique (stop_id, shipment_nbr)
);

-- Checklist lines, grouped by invoice. expected_qty = what the checker let out.
create table public.lm_stop_lines (
  id            bigint generated always as identity primary key,
  stop_id       bigint not null references public.lm_stops(id) on delete cascade,
  shipment_nbr  text not null,
  line_nbr      int not null,
  inventory_id  text,
  description   text,
  uom           text,
  expected_qty  numeric not null check (expected_qty >= 0),
  delivered_qty numeric check (delivered_qty >= 0),    -- null until the driver has marked the line
  result        text check (result in ('delivered', 'short', 'refused', 'damaged')),
  reason_code   text references public.lm_reason_codes(code),
  note          text,
  unique (stop_id, shipment_nbr, line_nbr)
);

-- ------------------------------------------------------------------
-- Events (append-only)
-- ------------------------------------------------------------------
-- kind: ready, claim, rescan, unassign, shortage, seq_edit, on_the_way, arrived, line_set,
--       complete, abort_stop, abort_load, file, return_raised, close
create table public.lm_events (
  id          bigint generated always as identity primary key,
  event_uuid  uuid not null unique,                 -- replays of the same event are ignored
  load_id     bigint references public.loads(id) on delete set null,
  load_nbr    text,                                  -- copied so the audit reads well after a delete
  stop_id     bigint,                                -- no FK: stops may be deleted with their load
  kind        text not null,
  source      text not null check (source in ('driver', 'office', 'system')),
  device_id   uuid,
  actor_name  text,                                  -- office events
  client_at   timestamptz,                           -- the phone's clock
  server_at   timestamptz not null default now(),
  lat         double precision,
  lng         double precision,
  accuracy_m  real,
  applied     boolean not null default true,         -- false = logged but refused (invalid transition)
  reject_reason text,
  payload     jsonb not null default '{}'::jsonb
);
create index lm_events_load  on public.lm_events (load_id, id);
create index lm_events_stop  on public.lm_events (stop_id, id);
create index lm_events_kind  on public.lm_events (kind, server_at);

-- Rows can't be changed or removed. The one exception is the foreign key nulling
-- load_id when a load is deleted.
create function public._lm_events_immutable() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'UPDATE'
     and new.load_id is null and old.load_id is not null
     and (to_jsonb(new) - 'load_id') = (to_jsonb(old) - 'load_id') then
    return new;
  end if;
  raise exception 'lm_events is append-only';
end $$;
create trigger lm_events_immutable before update or delete on public.lm_events
  for each row execute function public._lm_events_immutable();

-- ------------------------------------------------------------------
-- Files (photos): the bytes live in the private storage bucket lm-pod
-- ------------------------------------------------------------------
create table public.lm_files (
  id            uuid primary key default gen_random_uuid(),
  load_id       bigint references public.loads(id) on delete set null,
  stop_id       bigint,
  kind          text not null check (kind in ('pod', 'damage', 'shortage', 'abort')),
  storage_path  text not null unique,
  shipment_nbrs text[] not null default '{}',        -- the invoices one photo covers
  taken_at      timestamptz,                          -- the phone's clock
  device_id     uuid,
  uploaded_at   timestamptz not null default now()
);
create index lm_files_load on public.lm_files (load_id);
create index lm_files_stop on public.lm_files (stop_id);

-- Private, images only, 10 MB. No storage.objects policy is added: only the service
-- role (the upload function, step 4) can reach it. Checked on 2026-10-22: every other
-- policy on storage.objects is scoped to a named bucket.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('lm-pod', 'lm-pod', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

-- ------------------------------------------------------------------
-- Returns: the digital return sheet. One per stop that has exceptions.
-- ------------------------------------------------------------------
create table public.lm_returns (
  id          bigint generated always as identity primary key,
  load_id     bigint not null references public.loads(id) on delete cascade,
  stop_id     bigint not null unique references public.lm_stops(id) on delete cascade,
  -- Phase 1 only uses 'raised'. The rest of the chain is here so Phase 2 (clerk
  -- receiving, credit memo draft, admin release) needs no change to the check.
  status      text not null default 'raised'
              check (status in ('raised', 'on_truck', 'received', 'credit_drafted', 'released')),
  raised_at   timestamptz not null default now(),
  raised_device uuid
);
create index lm_returns_load on public.lm_returns (load_id);

create table public.lm_return_lines (
  id            bigint generated always as identity primary key,
  return_id     bigint not null references public.lm_returns(id) on delete cascade,
  stop_line_id  bigint not null unique references public.lm_stop_lines(id) on delete cascade,
  shipment_nbr  text not null,
  line_nbr      int not null,
  inventory_id  text,
  description   text,
  uom           text,
  qty           numeric not null check (qty > 0),     -- not delivered
  reason_code   text not null references public.lm_reason_codes(code),
  note          text,
  file_id       uuid references public.lm_files(id) on delete set null,
  received_qty  numeric check (received_qty >= 0)     -- Phase 2: the clerk's count
);

-- ------------------------------------------------------------------
-- Devices: what the soft check remembers (client side too, but the server
-- warns on the review screen from this).
-- ------------------------------------------------------------------
create table public.lm_devices (
  device_id     uuid primary key,
  first_seen    timestamptz not null default now(),
  last_trucker  text,
  last_claim_at timestamptz
);

-- ------------------------------------------------------------------
-- RLS: staff can read; nobody writes directly
-- ------------------------------------------------------------------
create function public.lm_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from dispatch_roles
                  where user_id = auth.uid()
                    and role in ('batcher', 'clerk', 'supervisor', 'manager'));
$$;

alter table public.lm_reason_codes  enable row level security;
alter table public.lm_loads         enable row level security;
alter table public.lm_stops         enable row level security;
alter table public.lm_stop_invoices enable row level security;
alter table public.lm_stop_lines    enable row level security;
alter table public.lm_events        enable row level security;
alter table public.lm_files         enable row level security;
alter table public.lm_returns       enable row level security;
alter table public.lm_return_lines  enable row level security;
alter table public.lm_devices       enable row level security;

create policy lm_reason_codes_read  on public.lm_reason_codes  for select to authenticated using (public.dispatch_has_role());
create policy lm_loads_read         on public.lm_loads         for select to authenticated using (public.lm_staff());
create policy lm_stops_read         on public.lm_stops         for select to authenticated using (public.lm_staff());
create policy lm_stop_invoices_read on public.lm_stop_invoices for select to authenticated using (public.lm_staff());
create policy lm_stop_lines_read    on public.lm_stop_lines    for select to authenticated using (public.lm_staff());
create policy lm_events_read        on public.lm_events        for select to authenticated using (public.lm_staff());
create policy lm_files_read         on public.lm_files         for select to authenticated using (public.lm_staff());
create policy lm_returns_read       on public.lm_returns       for select to authenticated using (public.lm_staff());
create policy lm_return_lines_read  on public.lm_return_lines  for select to authenticated using (public.lm_staff());
-- lm_devices: no policy; service functions only.

-- claim_code and token_hash are secrets. Staff can read lm_loads, but not those columns
-- (a column revoke does nothing while the table-level grant exists, so revoke the table
-- and grant the safe columns). The claim code is handed out only by lm_ensure_load, so
-- Control Tower must select named columns, never select *.
revoke select on public.lm_loads from authenticated;
grant select (load_id, status, trucker_key, claimed_at, claimed_name, shortage_note, delivering_at,
              completed_at, closed_at, closed_by, aborted_at, abort_reason, abort_note, created_at)
  on public.lm_loads to authenticated;

revoke all on public.lm_reason_codes, public.lm_loads, public.lm_stops, public.lm_stop_invoices,
  public.lm_stop_lines, public.lm_events, public.lm_files, public.lm_returns, public.lm_return_lines,
  public.lm_devices from anon;
revoke insert, update, delete, truncate on public.lm_reason_codes, public.lm_loads, public.lm_stops,
  public.lm_stop_invoices, public.lm_stop_lines, public.lm_events, public.lm_files, public.lm_returns,
  public.lm_return_lines, public.lm_devices from authenticated;
revoke all on public.lm_devices from authenticated;

-- ------------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------------

-- The trucker a Ship Via belongs to. base_trucker is still empty, so for now every
-- code is its own trucker; filling base_trucker needs no change here.
create function public.lm_trucker_key(p_ship_via text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select nullif(trim(base_trucker), '') from ship_via_codes where ship_via = p_ship_via),
                  p_ship_via);
$$;

-- 8 characters, no I L O U, so it can be typed from paper. 32^8 is about 1.1e12.
create function public._lm_new_claim_code() returns text
language plpgsql volatile set search_path = public, extensions as $$
declare
  alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  code text; b bytea; i int;
begin
  loop
    b := gen_random_bytes(8);
    code := '';
    for i in 0..7 loop
      code := code || substr(alphabet, (get_byte(b, i) % 32) + 1, 1);
    end loop;
    exit when not exists (select 1 from lm_loads where claim_code = code);
  end loop;
  return code;
end $$;

-- Append an event. Replays of the same event_uuid are ignored (returns null).
create function public._lm_event(p_load_id bigint, p_kind text, p_source text,
                                 p_stop_id bigint default null, p_device uuid default null,
                                 p_client_at timestamptz default null,
                                 p_lat double precision default null, p_lng double precision default null,
                                 p_accuracy real default null, p_payload jsonb default '{}'::jsonb,
                                 p_event uuid default null, p_applied boolean default true,
                                 p_reject text default null, p_actor text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare nbr text; new_id bigint;
begin
  select load_nbr into nbr from loads where loads.id = p_load_id;
  insert into lm_events (event_uuid, load_id, load_nbr, stop_id, kind, source, device_id, actor_name,
                         client_at, lat, lng, accuracy_m, applied, reject_reason, payload)
  values (coalesce(p_event, gen_random_uuid()), p_load_id, nbr, p_stop_id, p_kind, p_source, p_device, p_actor,
          p_client_at, p_lat, p_lng, p_accuracy, p_applied, p_reject, coalesce(p_payload, '{}'::jsonb))
  on conflict (event_uuid) do nothing
  returning lm_events.id into new_id;
  return new_id;
end $$;

-- Staff: make a checker-confirmed load claimable and return its claim code, for the
-- load sheet. Safe to call again; the code never changes once issued.
create function public.lm_ensure_load(p_load_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare l loads; code text;
begin
  if auth.uid() is null or not dispatch_has_role() then
    raise exception 'Your account doesn''t have a dispatch role' using errcode = '42501';
  end if;
  select * into l from loads where id = p_load_id;
  if not found then raise exception 'Load not found'; end if;
  if l.check_status is distinct from 'confirmed' then
    raise exception '% has not been confirmed by the checker yet', l.load_nbr;
  end if;

  select claim_code into code from lm_loads where load_id = p_load_id;
  if code is null then
    perform pg_advisory_xact_lock(hashtext('lm_ensure:' || p_load_id::text));
    select claim_code into code from lm_loads where load_id = p_load_id;
    if code is null then
      code := _lm_new_claim_code();
      insert into lm_loads (load_id, claim_code) values (p_load_id, code);
      perform _lm_event(p_load_id, 'ready', 'office', p_actor := dispatch_actor_name());
    end if;
  end if;
  return code;
end $$;

-- ------------------------------------------------------------------
-- Grants: helpers are internal. Only lm_ensure_load is callable by staff.
-- ------------------------------------------------------------------
revoke all on function public.lm_staff()                       from public, anon;
revoke all on function public.lm_trucker_key(text)             from public, anon, authenticated;
revoke all on function public._lm_new_claim_code()             from public, anon, authenticated;
revoke all on function public._lm_event(bigint, text, text, bigint, uuid, timestamptz, double precision,
                                        double precision, real, jsonb, uuid, boolean, text, text)
                                                               from public, anon, authenticated;
revoke all on function public._lm_events_immutable()           from public, anon, authenticated;
revoke all on function public.lm_ensure_load(bigint)           from public, anon;
grant execute on function public.lm_staff()                    to authenticated;
grant execute on function public.lm_ensure_load(bigint)        to authenticated;

-- ------------------------------------------------------------------
-- Rollback (by hand; drops everything this file adds, including any driver data)
-- ------------------------------------------------------------------
-- drop function public.lm_ensure_load(bigint);
-- drop function public._lm_event(bigint, text, text, bigint, uuid, timestamptz, double precision, double precision, real, jsonb, uuid, boolean, text, text);
-- drop function public._lm_new_claim_code();
-- drop function public.lm_trucker_key(text);
-- drop function public.lm_staff();
-- drop table public.lm_return_lines, public.lm_returns, public.lm_files, public.lm_events,
--   public.lm_stop_lines, public.lm_stop_invoices, public.lm_stops, public.lm_loads,
--   public.lm_devices, public.lm_reason_codes;
-- drop function public._lm_events_immutable();
-- delete from storage.buckets where id = 'lm-pod';   -- only once the bucket is empty
