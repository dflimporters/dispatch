-- 2026-11-13. Transfer window = since the previous list's cut-off (Joel).
--
-- A list run at 2pm must capture every order placed since the previous 2pm run (Monday's list covers the weekend).
-- Each list therefore starts where the last one in the same env ended: no gaps, no overlaps. With no earlier list
-- the window is the last 24 hours. A fixed number of hours can still be chosen (p_hours); null = since the last list.
-- A last list older than 5 days is ignored (back to 24 hours) so a long-forgotten list can't stretch the window.
--
-- SAFETY NET for sync lag. Orders are counted by their Acumatica created time, but this copy refreshes every few
-- minutes: an order entered at 1:58pm and synced at 2:10pm would miss a 2:05pm list and, by creation time alone, the
-- next one too. So in "since the last list" mode a list also takes any open order created up to 12 hours before the
-- previous cut-off that is not on any earlier list of this env (every order in a list's window is saved with it,
-- counted or not). These are flagged late (transfer_list_orders.late) and shown on the page. Only applies when an earlier
-- list exists, and never in fixed-hours mode.
--
-- Lists are numbered TR-DDMM-NN, like load numbers (L-DDMM-NN).
-- Deleting a draft hands its window back to the next list. cutoff_from / window_hours on the list record what it covered.
--
-- Rollback: restore the previous definitions from 20261113120000_transfer_from_orders.sql.

drop function public.dispatch_transfer_preview(text, numeric, int, boolean, int, timestamptz);
drop function public.dispatch_transfer_window(int, int, boolean, timestamptz);
drop function public.dispatch_transfer_build(text, numeric, timestamptz, jsonb, text, int, boolean, int);
drop function public._dispatch_transfer_orders(int, int, timestamptz);

alter table public.transfer_list_orders add column late boolean not null default false;

-- End of the previous list in this env (any status; a deleted draft no longer exists), else null.
create function public._dispatch_transfer_from(p_env text, p_hours int, p_to timestamptz) returns timestamptz
language sql stable security definer set search_path = public as $$
  select case when p_hours is not null and p_hours > 0 then p_to - make_interval(hours => p_hours)
              else coalesce((select max(cutoff_to) from transfer_lists where env = p_env and cutoff_to < p_to and cutoff_to > p_to - interval '5 days'), p_to - interval '24 hours') end;
$$;
revoke all on function public._dispatch_transfer_from(text, int, timestamptz) from public, anon, authenticated;

-- Carry-over applies only in since-the-last-list mode with an earlier list.
create function public._dispatch_transfer_carry(p_env text, p_hours int, p_from timestamptz) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(p_hours, 0) <= 0 and exists (select 1 from transfer_lists where env = p_env and cutoff_to = p_from);
$$;
revoke all on function public._dispatch_transfer_carry(text, int, timestamptz) from public, anon, authenticated;

create function public._dispatch_transfer_orders(p_from timestamptz, p_horizon_hours int, p_to timestamptz,
                                                 p_env text default null, p_carry boolean default false)
returns table (order_nbr text, customer_name text, status text, created_on timestamptz, sched_shipment date, far_dated boolean, late boolean)
language sql stable security definer set search_path = public as $$
  select o.order_nbr::text, o.customer_name::text, o.status::text, o.created_on::timestamptz, o.sched_shipment::date,
         (o.sched_shipment is not null
          and o.sched_shipment::timestamp > (p_to at time zone 'America/Jamaica') + make_interval(hours => greatest(p_horizon_hours, 0))),
         (o.created_on::timestamptz <= p_from)
    from sales_orders o
   where o.order_type = 'SO' and o.status in ('Open', 'Back Order')
     and o.created_on::timestamptz <= p_to
     and (o.created_on::timestamptz > p_from
          or (p_carry and o.created_on::timestamptz > p_from - interval '12 hours'
              and not exists (select 1 from transfer_list_orders x join transfer_lists t on t.id = x.list_id
                               where t.env = p_env and x.order_nbr = o.order_nbr)));
$$;
revoke all on function public._dispatch_transfer_orders(timestamptz, int, timestamptz, text, boolean) from public, anon, authenticated;

create function public.dispatch_transfer_preview(p_env text, p_extra_pct numeric default 10, p_hours int default null,
                                                 p_include_far boolean default false, p_horizon_hours int default 48,
                                                 p_to timestamptz default null)
returns table (section text, inventory_id text, description text, demand numeric, bumped numeric, orders int, far_orders int,
               on_hand_71 numeric, on_hand_ash numeric, suggested numeric, volume numeric, cases_per_pallet numeric,
               in_transit text, cutoff_from timestamptz, cutoff_to timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare v_to timestamptz := least(coalesce(p_to, now()), now()); v_from timestamptz;
begin
  if not dispatch_has_role('batcher') then raise exception 'Your account doesn''t have the coordinator role' using errcode = '42501'; end if;
  v_from := _dispatch_transfer_from(p_env, p_hours, v_to);
  return query
  with ord as (select * from _dispatch_transfer_orders(v_from, p_horizon_hours, v_to, p_env, _dispatch_transfer_carry(p_env, p_hours, v_from))),
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
         st.volume, p.cases_per_pallet, tr.list_nbr, v_from, v_to
    from agg a
    left join st on st.inventory_id = a.inv
    left join item_pallet_sizes p on p.inventory_id = a.inv
    left join transit tr on tr.inventory_id = a.inv
   where a.demand > coalesce(st.oh71, 0)
   order by (a.demand - coalesce(st.oh71, 0)) desc;
end $$;

-- Window summary for the page. 'since' = the list whose cut-off the window starts from (null when a fixed number of hours is chosen).
create function public.dispatch_transfer_window(p_hours int default null, p_horizon_hours int default 48, p_include_far boolean default false,
                                                p_to timestamptz default null, p_env text default 'live')
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_to timestamptz := least(coalesce(p_to, now()), now()); v_from timestamptz; r jsonb; v_since text;
begin
  if not dispatch_has_role('batcher') then raise exception 'Your account doesn''t have the coordinator role' using errcode = '42501'; end if;
  v_from := _dispatch_transfer_from(p_env, p_hours, v_to);
  if p_hours is null or p_hours <= 0 then
    select list_nbr into v_since from transfer_lists where env = p_env and cutoff_to = v_from order by id desc limit 1;
  end if;
  select jsonb_build_object('orders', count(*), 'far_orders', count(*) filter (where far_dated),
           'far_list', coalesce(jsonb_agg(jsonb_build_object('order_nbr', order_nbr, 'customer', customer_name, 'ship_on', sched_shipment)
                          order by sched_shipment) filter (where far_dated), '[]'::jsonb),
           'late_orders', count(*) filter (where late),
           'late_list', coalesce(jsonb_agg(jsonb_build_object('order_nbr', order_nbr, 'customer', customer_name, 'created_on', created_on)
                          order by created_on) filter (where late), '[]'::jsonb),
           'from', v_from, 'to', v_to, 'since', v_since)
    into r from _dispatch_transfer_orders(v_from, p_horizon_hours, v_to, p_env, _dispatch_transfer_carry(p_env, p_hours, v_from));
  return r;
end $$;

create function public.dispatch_transfer_build(p_env text, p_extra_pct numeric, p_cutoff_to timestamptz, p_lines jsonb,
                                               p_note text default null, p_hours int default null, p_include_far boolean default false,
                                               p_horizon_hours int default 48)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_seq int; v_id bigint; v_date date := (now() at time zone 'America/Jamaica')::date; v_orders int; v_from timestamptz;
begin
  perform _dispatch_require('batcher');
  perform pg_advisory_xact_lock(hashtext('transfer:' || p_env));
  if exists (select 1 from transfer_lists where env = p_env and status = 'draft') then
    raise exception 'There''s already a draft transfer list; send or delete it first';
  end if;
  if p_cutoff_to is null or p_cutoff_to > now() then raise exception 'The preview is out of date; refresh it and build again'; end if;
  v_from := _dispatch_transfer_from(p_env, p_hours, p_cutoff_to);
  select coalesce(max(seq), 0) + 1 into v_seq from transfer_lists where env = p_env and list_date = v_date;
  insert into transfer_lists (env, list_date, seq, list_nbr, cutoff_from, cutoff_to, extra_pct, note, built_name, window_hours, horizon_hours, include_far)
  values (p_env, v_date, v_seq, 'TR-' || to_char(v_date, 'DDMM') || '-' || lpad(v_seq::text, 2, '0'),
          v_from, p_cutoff_to, p_extra_pct, nullif(trim(p_note), ''),
          dispatch_actor_name(), greatest(1, round(extract(epoch from (p_cutoff_to - v_from)) / 3600)::int), p_horizon_hours, p_include_far)
  returning id into v_id;

  insert into transfer_list_orders (list_id, order_nbr, customer_name, status, created_on, sched_shipment, far_dated, counted, late)
  select v_id, o.order_nbr, o.customer_name, o.status, o.created_on, o.sched_shipment, o.far_dated, (p_include_far or not o.far_dated), o.late
    from _dispatch_transfer_orders(v_from, p_horizon_hours, p_cutoff_to, p_env, _dispatch_transfer_carry(p_env, p_hours, v_from)) o;
  select count(*) into v_orders from transfer_list_orders where list_id = v_id and counted;
  update transfer_lists set order_count = v_orders where id = v_id;

  insert into transfer_lines (list_id, inventory_id, section, description, bumped, demand, orders, far_orders, on_hand_71, on_hand_ash,
                              suggested, send_qty, included, volume, cases_per_pallet)
  select v_id, p.inventory_id, p.section, p.description, p.bumped, p.demand, p.orders, p.far_orders, p.on_hand_71, p.on_hand_ash, p.suggested,
         greatest(0, round(coalesce((x->>'send_qty')::numeric, p.suggested))),
         coalesce((x->>'included')::boolean, p.in_transit is null), p.volume, p.cases_per_pallet
    from dispatch_transfer_preview(p_env, p_extra_pct, p_hours, p_include_far, p_horizon_hours, p_cutoff_to) p
    left join jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) x on x->>'inventory_id' = p.inventory_id;

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

revoke all on function public.dispatch_transfer_preview(text, numeric, int, boolean, int, timestamptz) from public, anon;
revoke all on function public.dispatch_transfer_window(int, int, boolean, timestamptz, text) from public, anon;
revoke all on function public.dispatch_transfer_build(text, numeric, timestamptz, jsonb, text, int, boolean, int) from public, anon;
grant execute on function public.dispatch_transfer_preview(text, numeric, int, boolean, int, timestamptz) to authenticated;
grant execute on function public.dispatch_transfer_window(int, int, boolean, timestamptz, text) to authenticated;
grant execute on function public.dispatch_transfer_build(text, numeric, timestamptz, jsonb, text, int, boolean, int) to authenticated;
