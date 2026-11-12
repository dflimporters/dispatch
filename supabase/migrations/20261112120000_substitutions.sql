-- 2026-11-12. Item substitution through the API (Joel).
--
-- The checker flags a short line (check_items.sub_needed). The invoicer then picks the replacement item on the
-- Invoicing page and gives a quantity for each customer on the flag. For each customer the dispatch-sub edge
-- function makes a separate SO (an SO can only belong to one customer), releases it from credit hold, creates the
-- shipment, sets its Ship Via, confirms it, and joins it to the same load here. One row per customer line below,
-- with the last step that finished, so a failure resumes where it stopped and a retry never makes a second SO
-- (ref is the Customer Order Nbr stamped on the SO and is looked up before anything is created).
--
-- Only the service role writes this table (the edge function). Dispatch staff can read it.
-- Rollback at the bottom.

create table public.substitutions (
  id                  bigint generated always as identity primary key,
  env                 text   not null check (env in ('live', 'test')),
  load_id             bigint not null references public.loads(id) on delete cascade,
  source_inventory_id text   not null,            -- the item the checker couldn't find
  orig_shipment_nbr   text   not null,            -- the customer's shipment it was short on
  orig_order_type     text,
  orig_order_nbr      text,
  orig_order_line     int,
  customer_id         text   not null,
  customer_name       text,
  sub_inventory_id    text   not null,            -- the replacement item
  sub_description     text,
  uom                 text,
  qty                 numeric not null check (qty > 0),
  ref                 text   not null unique,     -- Customer Order Nbr on the new SO (idempotency key)
  state               text   not null default 'queued' check (state in ('queued', 'running', 'done', 'failed')),
  -- last step that finished: none -> so -> released -> shipment -> shipvia -> confirmed -> joined
  step                text   not null default 'none' check (step in ('none', 'so', 'released', 'shipment', 'shipvia', 'confirmed', 'joined')),
  new_order_nbr       text,
  new_shipment_nbr    text,
  unit_price          numeric,
  error               text,
  requested_by        uuid,
  requested_name      text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  -- One substitution per customer shipment and flagged item.
  unique (env, load_id, source_inventory_id, orig_shipment_nbr)
);
create index substitutions_load on public.substitutions (load_id);

alter table public.substitutions enable row level security;
create policy substitutions_read on public.substitutions for select to authenticated
  using (public.dispatch_has_role());
revoke all on public.substitutions from public, anon;
grant select on public.substitutions to authenticated;

-- Join a finished substitute shipment to its load. Called by dispatch-sub with what it read back from Acumatica:
--   p_header = { shipment_nbr, status, shipment_date, customer_id, customer_name, warehouse_id, shipping_zone,
--                ship_via, shipped_qty, order_nbr, ordered_qty, shipment_value }
--   p_lines  = [ { line_nbr, inventory_id, description, uom, ordered_qty, shipped_qty, order_nbr, order_line_nbr,
--                  location_id, unit_price, line_value } ]
-- Writes the shipment and its lines into the env's mirror (the next sync rewrites them from Acumatica), puts the
-- shipment on the load as already written and already checked (it was confirmed by the API), marks the printed load
-- sheet stale so it is reprinted, and logs it on the load. Safe to run twice.
create function public._substitution_join_load(p_id bigint, p_header jsonb, p_lines jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare s substitutions; l loads; n text;
begin
  select * into s from substitutions where id = p_id for update;
  if not found then raise exception 'Substitution % not found', p_id; end if;
  select * into l from loads where id = s.load_id for update;
  if not found then raise exception 'Load not found (it may have been deleted)'; end if;
  if l.env <> s.env then raise exception 'Load % is not a % load', l.load_nbr, s.env; end if;
  n := p_header->>'shipment_nbr';
  if n is null then raise exception 'No shipment number'; end if;

  if s.env = 'test' then
    insert into shipments_test (shipment_nbr, shipment_type, operation, status, shipment_date, customer_id, customer_name,
                                warehouse_id, shipping_zone, ship_via, shipped_qty, order_type, order_nbr, ordered_qty, shipment_value, synced_at)
    values (n, 'Shipment', 'Issue', coalesce(p_header->>'status', 'Confirmed'), (p_header->>'shipment_date')::date,
            p_header->>'customer_id', p_header->>'customer_name', p_header->>'warehouse_id', p_header->>'shipping_zone',
            p_header->>'ship_via', (p_header->>'shipped_qty')::numeric, 'SO', p_header->>'order_nbr',
            (p_header->>'ordered_qty')::numeric, (p_header->>'shipment_value')::numeric, now())
    on conflict (shipment_nbr) do update set status = excluded.status, ship_via = excluded.ship_via,
      shipped_qty = excluded.shipped_qty, shipment_value = excluded.shipment_value, synced_at = now();
  else
    insert into shipments (shipment_nbr, shipment_type, operation, status, shipment_date, customer_id, customer_name,
                           warehouse_id, shipping_zone, ship_via, shipped_qty, order_type, order_nbr, ordered_qty, shipment_value, synced_at)
    values (n, 'Shipment', 'Issue', coalesce(p_header->>'status', 'Confirmed'), (p_header->>'shipment_date')::date,
            p_header->>'customer_id', p_header->>'customer_name', p_header->>'warehouse_id', p_header->>'shipping_zone',
            p_header->>'ship_via', (p_header->>'shipped_qty')::numeric, 'SO', p_header->>'order_nbr',
            (p_header->>'ordered_qty')::numeric, (p_header->>'shipment_value')::numeric, now())
    on conflict (shipment_nbr) do update set status = excluded.status, ship_via = excluded.ship_via,
      shipped_qty = excluded.shipped_qty, shipment_value = excluded.shipment_value, synced_at = now();
  end if;

  insert into shipment_lines (env, shipment_nbr, line_nbr, inventory_id, description, uom, ordered_qty, shipped_qty,
                              order_type, order_nbr, order_line_nbr, location_id, unit_price, line_value, synced_at)
  select s.env, n, (x->>'line_nbr')::int, x->>'inventory_id', x->>'description', x->>'uom', (x->>'ordered_qty')::numeric,
         (x->>'shipped_qty')::numeric, 'SO', x->>'order_nbr', (x->>'order_line_nbr')::int, x->>'location_id',
         (x->>'unit_price')::numeric, (x->>'line_value')::numeric, now()
    from jsonb_array_elements(p_lines) x
  on conflict (env, shipment_nbr, line_nbr) do update set shipped_qty = excluded.shipped_qty, ordered_qty = excluded.ordered_qty,
    unit_price = excluded.unit_price, line_value = excluded.line_value, synced_at = now();

  insert into load_shipments (env, shipment_nbr, load_id, ship_via_before, result, result_detail, result_at,
                              check_result, check_detail, check_at)
  values (s.env, n, s.load_id, p_header->>'ship_via', 'applied', 'Substitute for ' || s.source_inventory_id, now(),
          'applied', 'Substitute for ' || s.source_inventory_id, now())
  on conflict (env, shipment_nbr) do nothing;
  if not exists (select 1 from load_shipments where env = s.env and shipment_nbr = n and load_id = s.load_id) then
    raise exception 'Shipment % is already on another load', n;
  end if;

  update loads set sheet_stale_at = now() where id = l.id;
  insert into load_events (load_id, env, load_nbr, kind, note, detail, actor_name)
  values (l.id, l.env, l.load_nbr, 'substitute',
          s.customer_name || ': ' || s.sub_inventory_id || ' x ' || s.qty || ' in place of ' || s.source_inventory_id
            || ' (SO ' || coalesce(s.new_order_nbr, '?') || ', shipment ' || n || ')',
          jsonb_build_object('substitution_id', s.id, 'shipment', n, 'order', s.new_order_nbr), s.requested_name);

  update substitutions set step = 'joined', state = 'done', error = null, new_shipment_nbr = n, updated_at = now() where id = s.id;
end $$;
revoke all on function public._substitution_join_load(bigint, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public._substitution_join_load(bigint, jsonb, jsonb) to service_role;

-- Rollback:
-- drop function public._substitution_join_load(bigint, jsonb, jsonb);
-- drop table public.substitutions;
