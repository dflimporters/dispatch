-- 2026-11-13. Transfer lists built from open SALES ORDERS, not shipments (Joel).
-- See docs/transfer-cycle.md.
--
-- Cycle: SO cut-off 2pm; the coordinator presses Build; the list is vetted and sent to Ashenheim (Mark sent);
-- the transfer arrives at 71 and is released in Acumatica (Mark received at 71); only then does the late-night
-- batcher batch the orders that were in the cycle.
--
-- Demand per item = open qty on the open SOs created in the window (default the last 24 hours, selectable),
-- less what is on hand at 71. Suggested = need + extra %. Pallets come from item_pallet_sizes; containers are
-- estimated from the pallets (the page holds pallets per container, default 20).
--
-- Ship date: orders whose Ship On date is more than horizon hours past the cut-off (default 48) are left out
-- unless the coordinator ticks "include". Every order in the window is saved with the list (transfer_list_orders)
-- with counted / far_dated flags: that snapshot is what the batcher sees, so orders that arrive after the
-- cut-off are never batched against the transfer's stock.
--
-- In transit = on a list that is sent but not yet received (and sent within the last 12 hours), left unticked.
-- Manual lines: items that were never on the list can be added to a preview or a draft (section 'manual').
--
-- Rollback: restore the previous functions from 20261007150000_transfer_lists.sql and drop the new columns/table.

-- ------------------------------------------------------------------ tables
alter table public.transfer_lists
  add column window_hours   int     not null default 24,
  add column horizon_hours  int     not null default 48,
  add column include_far    boolean not null default false,
  add column order_count    int,
  add column received_by    uuid, add column received_name text, add column received_at timestamptz;
alter table public.transfer_lists drop constraint transfer_lists_status_check;
alter table public.transfer_lists add constraint transfer_lists_status_check check (status in ('draft', 'sent', 'received'));

alter table public.transfer_lines
  add column demand        numeric,
  add column far_orders    int,
  add column volume        numeric,         -- per case
  add column cases_per_pallet numeric;
alter table public.transfer_lines drop constraint transfer_lines_section_check;
alter table public.transfer_lines add constraint transfer_lines_section_check check (section in ('new', 'earlier', 'manual'));

create table public.transfer_list_orders (
  list_id       bigint not null references public.transfer_lists(id) on delete cascade,
  order_nbr     text   not null,
  customer_name text,
  status        text,
  created_on    timestamptz,
  sched_shipment date,
  far_dated     boolean not null default false,
  counted       boolean not null default true,   -- false: left out of the list as shipping beyond the horizon
  primary key (list_id, order_nbr)
);
create index transfer_list_orders_order on public.transfer_list_orders (order_nbr);
alter table public.transfer_list_orders enable row level security;
create policy transfer_list_orders_read on public.transfer_list_orders for select to authenticated using (public.dispatch_has_role());
revoke all on public.transfer_list_orders from anon;
revoke insert, update, delete, truncate on public.transfer_list_orders from authenticated;

-- ------------------------------------------------------------------ helpers
drop function public.dispatch_transfer_preview(text, numeric);
drop function public.dispatch_transfer_build(text, numeric, timestamptz, jsonb, text);
drop function public._dispatch_transfer_from(text);

-- Open SOs created in the window, with whether they ship beyond the horizon.
create function public._dispatch_transfer_orders(p_hours int, p_horizon_hours int, p_to timestamptz)
returns table (order_nbr text, customer_name text, status text, created_on timestamptz, sched_shipment date, far_dated boolean)
language sql stable security definer set search_path = public as $$
  select o.order_nbr::text, o.customer_name::text, o.status::text, o.created_on::timestamptz, o.sched_shipment::date,
         (o.sched_shipment is not null
          and o.sched_shipment::timestamp > (p_to at time zone 'America/Jamaica') + make_interval(hours => greatest(p_horizon_hours, 0)))
    from sales_orders o
   where o.order_type = 'SO' and o.status in ('Open', 'Back Order')
     and o.created_on::timestamptz >  p_to - make_interval(hours => greatest(p_hours, 1))
     and o.created_on::timestamptz <= p_to;
$$;
revoke all on function public._dispatch_transfer_orders(int, int, timestamptz) from public, anon, authenticated;

-- Latest stock / volume reading per item (SOOrderedItems GI, refreshed every 5 minutes).
create function public._dispatch_transfer_stock() returns table (inventory_id text, descr text, oh71 numeric, ohash numeric, volume numeric)
language sql stable security definer set search_path = public as $$
  select distinct on (o.inventory_id) o.inventory_id::text, o.line_description::text, coalesce(o.qty_on_hand_71, 0),
         coalesce(o.qty_on_hand_ash, 0), o.volume::numeric
    from so_ordered_items o
   where o.inventory_id is not null and o.synced_at > now() - interval '2 days'
   order by o.inventory_id, o.synced_at desc;
$$;
revoke all on function public._dispatch_transfer_stock() from public, anon, authenticated;

-- ------------------------------------------------------------------ preview
create function public.dispatch_transfer_preview(p_env text, p_extra_pct numeric default 10, p_hours int default 24,
                                                 p_include_far boolean default false, p_horizon_hours int default 48,
                                                 p_to timestamptz default null)
returns table (section text, inventory_id text, description text, demand numeric, bumped numeric, orders int, far_orders int,
               on_hand_71 numeric, on_hand_ash numeric, suggested numeric, volume numeric, cases_per_pallet numeric,
               in_transit text, cutoff_from timestamptz, cutoff_to timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare v_to timestamptz := least(coalesce(p_to, now()), now());
begin
  if not dispatch_has_role('batcher') then raise exception 'Your account doesn''t have the coordinator role' using errcode = '42501'; end if;
  return query
  with ord as (select * from _dispatch_transfer_orders(p_hours, p_horizon_hours, v_to)),
  ln as (
    select i.inventory_id::text inv, max(i.line_description)::text descr, i.order_nbr, sum(i.open_qty) qty, o.far_dated
      from ord o join so_ordered_items i on i.order_nbr = o.order_nbr and i.order_type = 'SO'
     where i.open_qty > 0 and coalesce(i.inventory_id, '') <> '' and (p_include_far or not o.far_dated)
     group by 1, 3, 5
  ),
  agg as (
    select ln.inv, max(ln.descr) descr, sum(ln.qty) demand, count(*)::int orders, (count(*) filter (where ln.far_dated))::int far_orders
      from ln group by 1
  ),
  st as (select * from _dispatch_transfer_stock()),
  transit as (
    select distinct on (tl.inventory_id) tl.inventory_id, t.list_nbr
      from transfer_lines tl join transfer_lists t on t.id = tl.list_id
     where t.env = p_env and t.status = 'sent' and tl.included and tl.send_qty > 0 and t.sent_at > now() - interval '12 hours'
     order by tl.inventory_id, t.sent_at desc
  )
  select 'new'::text, a.inv, coalesce(a.descr, st.descr), a.demand, a.demand - coalesce(st.oh71, 0), a.orders, a.far_orders,
         coalesce(st.oh71, 0), coalesce(st.ohash, 0),
         ceil((a.demand - coalesce(st.oh71, 0)) * (1 + greatest(p_extra_pct, 0) / 100.0)),
         st.volume, p.cases_per_pallet, tr.list_nbr, v_to - make_interval(hours => greatest(p_hours, 1)), v_to
    from agg a
    left join st on st.inventory_id = a.inv
    left join item_pallet_sizes p on p.inventory_id = a.inv
    left join transit tr on tr.inventory_id = a.inv
   where a.demand > coalesce(st.oh71, 0)
   order by (a.demand - coalesce(st.oh71, 0)) desc;
end $$;

-- Window summary for the page: orders in the window, how many ship beyond the horizon, whether they're included.
create function public.dispatch_transfer_window(p_hours int default 24, p_horizon_hours int default 48, p_include_far boolean default false,
                                                p_to timestamptz default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_to timestamptz := least(coalesce(p_to, now()), now()); r jsonb;
begin
  if not dispatch_has_role('batcher') then raise exception 'Your account doesn''t have the coordinator role' using errcode = '42501'; end if;
  select jsonb_build_object('orders', count(*), 'far_orders', count(*) filter (where far_dated),
           'far_list', coalesce(jsonb_agg(jsonb_build_object('order_nbr', order_nbr, 'customer', customer_name, 'ship_on', sched_shipment)
                          order by sched_shipment) filter (where far_dated), '[]'::jsonb),
           'from', v_to - make_interval(hours => greatest(p_hours, 1)), 'to', v_to)
    into r from _dispatch_transfer_orders(p_hours, p_horizon_hours, v_to);
  return r;
end $$;

-- Manual add: item lookup with its stock, volume and pallet size.
create function public.dispatch_transfer_item_info(p_inventory_id text)
returns table (inventory_id text, description text, on_hand_71 numeric, on_hand_ash numeric, volume numeric, cases_per_pallet numeric)
language sql stable security definer set search_path = public as $$
  select s.inventory_id, s.description, st.oh71, st.ohash, st.volume, p.cases_per_pallet
    from stock_items_raw s
    left join _dispatch_transfer_stock() st on st.inventory_id = s.inventory_id
    left join item_pallet_sizes p on p.inventory_id = s.inventory_id
   where dispatch_has_role('batcher') and s.inventory_id = p_inventory_id
   limit 1;
$$;

-- ------------------------------------------------------------------ build
-- p_lines: [{inventory_id, send_qty, included, manual?}] from the preview the coordinator was looking at.
-- Numbers come from the preview rebuilt at p_cutoff_to; only quantities, ticks and manual items come from the page.
create function public.dispatch_transfer_build(p_env text, p_extra_pct numeric, p_cutoff_to timestamptz, p_lines jsonb,
                                               p_note text default null, p_hours int default 24, p_include_far boolean default false,
                                               p_horizon_hours int default 48)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_seq int; v_id bigint; v_date date := (now() at time zone 'America/Jamaica')::date; v_orders int;
begin
  perform _dispatch_require('batcher');
  perform pg_advisory_xact_lock(hashtext('transfer:' || p_env));
  if exists (select 1 from transfer_lists where env = p_env and status = 'draft') then
    raise exception 'There''s already a draft transfer list; send or delete it first';
  end if;
  if p_cutoff_to is null or p_cutoff_to > now() then raise exception 'The preview is out of date; refresh it and build again'; end if;
  select coalesce(max(seq), 0) + 1 into v_seq from transfer_lists where env = p_env and list_date = v_date;
  insert into transfer_lists (env, list_date, seq, list_nbr, cutoff_from, cutoff_to, extra_pct, note, built_name, window_hours, horizon_hours, include_far)
  values (p_env, v_date, v_seq, 'TR-' || to_char(v_date, 'MMDD') || '-' || lpad(v_seq::text, 2, '0'),
          p_cutoff_to - make_interval(hours => greatest(p_hours, 1)), p_cutoff_to, p_extra_pct, nullif(trim(p_note), ''),
          dispatch_actor_name(), greatest(p_hours, 1), p_horizon_hours, p_include_far)
  returning id into v_id;

  -- the snapshot of every order in the window
  insert into transfer_list_orders (list_id, order_nbr, customer_name, status, created_on, sched_shipment, far_dated, counted)
  select v_id, o.order_nbr, o.customer_name, o.status, o.created_on, o.sched_shipment, o.far_dated, (p_include_far or not o.far_dated)
    from _dispatch_transfer_orders(p_hours, p_horizon_hours, p_cutoff_to) o;
  select count(*) into v_orders from transfer_list_orders where list_id = v_id and counted;
  update transfer_lists set order_count = v_orders where id = v_id;

  insert into transfer_lines (list_id, inventory_id, section, description, bumped, demand, orders, far_orders, on_hand_71, on_hand_ash,
                              suggested, send_qty, included, volume, cases_per_pallet)
  select v_id, p.inventory_id, p.section, p.description, p.bumped, p.demand, p.orders, p.far_orders, p.on_hand_71, p.on_hand_ash, p.suggested,
         greatest(0, round(coalesce((x->>'send_qty')::numeric, p.suggested))),
         coalesce((x->>'included')::boolean, p.in_transit is null), p.volume, p.cases_per_pallet
    from dispatch_transfer_preview(p_env, p_extra_pct, p_hours, p_include_far, p_horizon_hours, p_cutoff_to) p
    left join jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) x on x->>'inventory_id' = p.inventory_id;

  -- manual items (never on the computed list)
  insert into transfer_lines (list_id, inventory_id, section, description, bumped, demand, orders, on_hand_71, on_hand_ash, suggested,
                              send_qty, included, volume, cases_per_pallet)
  select v_id, i.inventory_id, 'manual', i.description, 0, 0, 0, coalesce(i.on_hand_71, 0), coalesce(i.on_hand_ash, 0),
         greatest(0, round((x->>'send_qty')::numeric)), greatest(0, round((x->>'send_qty')::numeric)), true, i.volume, i.cases_per_pallet
    from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) x
    cross join lateral dispatch_transfer_item_info(x->>'inventory_id') i
   where coalesce((x->>'manual')::boolean, false)
     and not exists (select 1 from transfer_lines tl where tl.list_id = v_id and tl.inventory_id = i.inventory_id);
  return v_id;
end $$;

-- Add (or re-qty) a manual item on a draft.
create function public.dispatch_transfer_add_item(p_list_id bigint, p_inventory_id text, p_qty numeric)
returns void language plpgsql security definer set search_path = public as $$
declare i record;
begin
  perform _dispatch_require('batcher');
  if not exists (select 1 from transfer_lists where id = p_list_id and status = 'draft') then raise exception 'Only a draft list can be changed'; end if;
  select * into i from dispatch_transfer_item_info(p_inventory_id);
  if not found then raise exception 'Item % not found', p_inventory_id; end if;
  if coalesce(p_qty, 0) <= 0 then raise exception 'Enter a quantity above zero'; end if;
  insert into transfer_lines (list_id, inventory_id, section, description, bumped, demand, orders, on_hand_71, on_hand_ash, suggested,
                              send_qty, included, volume, cases_per_pallet)
  values (p_list_id, i.inventory_id, 'manual', i.description, 0, 0, 0, coalesce(i.on_hand_71, 0), coalesce(i.on_hand_ash, 0),
          round(p_qty), round(p_qty), true, i.volume, i.cases_per_pallet)
  on conflict (list_id, inventory_id) do update set send_qty = round(p_qty), included = true;
end $$;

-- ------------------------------------------------------------------ actions
-- draft -> sent -> received (the transfer is up and released into Acumatica at 71), or delete a draft.
create or replace function public.dispatch_transfer_action(p_list_id bigint, p_action text)
returns void language plpgsql security definer set search_path = public as $$
declare t transfer_lists;
begin
  perform _dispatch_require('batcher');
  select * into t from transfer_lists where id = p_list_id for update;
  if not found then raise exception 'List not found'; end if;
  if p_action = 'receive' then
    if t.status <> 'sent' then raise exception '% must be sent before it can be marked received', t.list_nbr; end if;
    update transfer_lists set status = 'received', received_by = auth.uid(), received_name = dispatch_actor_name(), received_at = now() where id = p_list_id;
    return;
  end if;
  if t.status <> 'draft' then raise exception '% has already been sent', t.list_nbr; end if;
  if p_action = 'send' then
    update transfer_lists set status = 'sent', sent_by = auth.uid(), sent_name = dispatch_actor_name(), sent_at = now() where id = p_list_id;
  elsif p_action = 'delete' then
    delete from transfer_lists where id = p_list_id;
  else raise exception 'Unknown action %', p_action;
  end if;
end $$;

-- ------------------------------------------------------------------ batch view
-- The latest list for the batcher: its orders and whether the transfer has been released at 71.
-- Orders created after the cut-off are not on it, so the batcher can see what must wait for the next cycle.
create function public.dispatch_transfer_cycle(p_env text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t transfer_lists; r jsonb;
begin
  if not dispatch_has_role('batcher') then raise exception 'Your account doesn''t have the coordinator role' using errcode = '42501'; end if;
  select * into t from transfer_lists where env = p_env and status in ('sent', 'received') order by built_at desc limit 1;
  if not found then return null; end if;
  select jsonb_build_object('list_nbr', t.list_nbr, 'status', t.status, 'cutoff_to', t.cutoff_to, 'sent_at', t.sent_at,
           'received_at', t.received_at, 'received_name', t.received_name,
           'orders', coalesce((select jsonb_agg(jsonb_build_object('order_nbr', x.order_nbr, 'customer', x.customer_name, 'counted', x.counted,
                         'far_dated', x.far_dated, 'ship_on', x.sched_shipment) order by x.order_nbr)
                       from transfer_list_orders x where x.list_id = t.id), '[]'::jsonb))
    into r;
  return r;
end $$;

-- ------------------------------------------------------------------ grants
revoke all on function public.dispatch_transfer_preview(text, numeric, int, boolean, int, timestamptz) from public, anon;
revoke all on function public.dispatch_transfer_window(int, int, boolean, timestamptz) from public, anon;
revoke all on function public.dispatch_transfer_item_info(text) from public, anon;
revoke all on function public.dispatch_transfer_build(text, numeric, timestamptz, jsonb, text, int, boolean, int) from public, anon;
revoke all on function public.dispatch_transfer_add_item(bigint, text, numeric) from public, anon;
revoke all on function public.dispatch_transfer_cycle(text) from public, anon;
grant execute on function public.dispatch_transfer_preview(text, numeric, int, boolean, int, timestamptz) to authenticated;
grant execute on function public.dispatch_transfer_window(int, int, boolean, timestamptz) to authenticated;
grant execute on function public.dispatch_transfer_item_info(text) to authenticated;
grant execute on function public.dispatch_transfer_build(text, numeric, timestamptz, jsonb, text, int, boolean, int) to authenticated;
grant execute on function public.dispatch_transfer_add_item(bigint, text, numeric) to authenticated;
grant execute on function public.dispatch_transfer_cycle(text) to authenticated;
