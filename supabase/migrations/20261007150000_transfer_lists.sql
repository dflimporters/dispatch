-- Transfer lists (Ashenheim -> 71), time-bound and numbered. Replaces the
-- running suggestion (dispatch_transfer_suggest) on transfers.html.
--
-- "Bumped" is per open SO order line: what's still open on the line minus what
-- made it onto open shipments (Open / On Hold). That catches lines that went
-- onto a shipment short AND lines Acumatica left off the shipment entirely.
-- Orders that got no shipment at all count only where 71 couldn't cover the
-- line (ship-complete customers, or nothing in stock).
--
-- Each list (TR-MMDD-NN) is built by the coordinator, frozen at build time, and
-- covers the window since the previous list's cut-off:
--   new      lines bumped off shipments created in this window
--   earlier  older bumps still open, and orders that couldn't ship at all
-- An item on a list marked Sent in the last 24 hours is "in transit" and left
-- out (shown, unticked). After 24 hours, if its order lines are still short,
-- it comes back under "earlier", so an item Ashenheim never sent can't drop off.
-- There is no receiving step yet: later the portal will read completed Transfer
-- Orders from Acumatica instead.
--
-- Suggested = bumped + extra %. Ashenheim's stock is NOT used (Joel 2026-10-07:
-- put it on the list and let Ashenheim decide what can come up). 71's current
-- stock is shown but not subtracted (bumping and building are minutes apart).
-- env 'live' reads so_ordered_items + live shipments; 'test' reads the orders
-- copied into TEST (dispatch_test_orders) + TEST shipments. Stock is always
-- production: QtyOnHand71 / QtyOnHandAsh from the SOOrderedItems GI.

create table public.transfer_lists (
  id          bigint generated always as identity primary key,
  env         text not null check (env in ('live', 'test')),
  list_date   date not null,
  seq         int  not null,
  list_nbr    text not null,                 -- TR-MMDD-NN
  status      text not null default 'draft' check (status in ('draft', 'sent')),
  cutoff_from timestamptz not null,
  cutoff_to   timestamptz not null,
  extra_pct   numeric not null,
  note        text,
  built_by    uuid default auth.uid(), built_name text, built_at timestamptz not null default now(),
  sent_by     uuid, sent_name text, sent_at timestamptz,
  unique (env, list_date, seq)
);
create table public.transfer_lines (
  list_id      bigint not null references public.transfer_lists(id) on delete cascade,
  inventory_id text   not null,
  section      text   not null check (section in ('new', 'earlier')),
  description  text,
  bumped       numeric not null,
  orders       int,
  on_hand_71   numeric,
  on_hand_ash  numeric,
  suggested    numeric not null,
  send_qty     numeric not null check (send_qty >= 0),
  included     boolean not null default true,
  primary key (list_id, inventory_id)
);
alter table public.transfer_lists enable row level security;
alter table public.transfer_lines enable row level security;
create policy transfer_lists_read on public.transfer_lists for select to authenticated using (public.dispatch_has_role());
create policy transfer_lines_read on public.transfer_lines for select to authenticated using (public.dispatch_has_role());
revoke all on public.transfer_lists, public.transfer_lines from anon;
revoke insert, update, delete, truncate on public.transfer_lists, public.transfer_lines from authenticated;

-- Where the next list starts: the last list's cut-off, else 24 hours ago.
create function public._dispatch_transfer_from(p_env text) returns timestamptz
language sql stable security definer set search_path = public as $$
  select coalesce((select max(cutoff_to) from transfer_lists where env = p_env), now() - interval '24 hours');
$$;

-- Preview of the next list (nothing saved). One row per item: what was bumped
-- in this window (new_qty) and before it (earlier_qty). section = 'new' when
-- anything was bumped in this window.
create function public.dispatch_transfer_preview(p_env text, p_extra_pct numeric default 10)
returns table (section text, inventory_id text, description text, bumped numeric, new_qty numeric, earlier_qty numeric,
               orders int, no_shipment int, oldest timestamptz, on_hand_71 numeric, on_hand_ash numeric,
               suggested numeric, in_transit text, cutoff_from timestamptz, cutoff_to timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare v_from timestamptz := _dispatch_transfer_from(p_env); v_to timestamptz := now();
begin
  if not dispatch_has_role('batcher') then raise exception 'Your account doesn''t have the coordinator role' using errcode = '42501'; end if;
  return query
  with ol as (                       -- open order lines
    select o.order_nbr, o.line_nbr, o.inventory_id, o.line_description descr, o.open_qty
      from so_ordered_items o
     where p_env = 'live' and o.order_type = 'SO' and o.open_qty > 0
       and o.order_status in ('Open', 'Back Order', 'Shipping') and o.order_date >= current_date - 14
    union all
    select t.test_order_nbr, (l->>'line')::int, l->>'inventory_id', null, (l->>'qty')::numeric
      from dispatch_test_orders t, jsonb_array_elements(coalesce(t.lines, '[]'::jsonb)) l
     where p_env = 'test' and t.test_order_nbr is not null
  ),
  -- Shipments that count against an order line. Live: open ones (OpenQty on the
  -- order already excludes confirmed shipments). Test: all of them (the copied
  -- orders' qty is the full ordered qty).
  sh as (
    select s.shipment_nbr, s.created_on from _dispatch_shipments(p_env) s
     where s.operation = 'Issue' and (p_env = 'test' or s.status in ('Open', 'On Hold'))
  ),
  onship as (
    select sl.order_nbr, sl.order_line_nbr, sum(sl.shipped_qty) qty
      from shipment_lines sl join sh on sh.shipment_nbr = sl.shipment_nbr
     where sl.env = p_env group by 1, 2
  ),
  ordship as (                       -- when the order first got a shipment
    select sl.order_nbr, min(sh.created_on) first_ship
      from shipment_lines sl join sh on sh.shipment_nbr = sl.shipment_nbr
     where sl.env = p_env group by 1
  ),
  -- Stock: QtyOnHand71 / QtyOnHandAsh from the SOOrderedItems GI (refreshed
  -- every 5 minutes), latest reading per item. stock_items_raw holds one
  -- warehouse per item, so it can't be used for this.
  stock as (
    select distinct on (o.inventory_id) o.inventory_id, coalesce(o.qty_on_hand_71, 0) oh71,
           coalesce(o.qty_on_hand_ash, 0) ohash, o.line_description descr
      from so_ordered_items o
     where o.inventory_id is not null and o.synced_at > now() - interval '2 days'
     order by o.inventory_id, o.synced_at desc
  ),
  b as (
    select ol.inventory_id, coalesce(ol.descr, st.descr) descr, ol.order_nbr,
           ol.open_qty - coalesce(os.qty, 0) bumped, oss.first_ship,
           coalesce(st.oh71, 0) oh71, coalesce(st.ohash, 0) ohash
      from ol
      left join onship os on os.order_nbr = ol.order_nbr and os.order_line_nbr = ol.line_nbr
      left join ordship oss on oss.order_nbr = ol.order_nbr
      left join stock st on st.inventory_id = ol.inventory_id
     where ol.open_qty - coalesce(os.qty, 0) > 0
       -- bumped off a shipment, or no shipment at all and 71 couldn't cover it
       and (oss.first_ship is not null or coalesce(st.oh71, 0) < ol.open_qty)
  ),
  agg as (
    select b.inventory_id, max(b.descr) descr, sum(b.bumped) bumped,
           coalesce(sum(b.bumped) filter (where b.first_ship > v_from), 0) new_qty,
           coalesce(sum(b.bumped) filter (where b.first_ship is null or b.first_ship <= v_from), 0) earlier_qty,
           count(distinct b.order_nbr)::int orders,
           count(distinct b.order_nbr) filter (where b.first_ship is null)::int no_ship,
           min(b.first_ship) oldest, max(b.oh71) oh71, max(b.ohash) ohash
      from b group by 1
  ),
  transit as (                       -- on a list sent in the last 24 hours
    select distinct on (tl.inventory_id) tl.inventory_id, t.list_nbr
      from transfer_lines tl join transfer_lists t on t.id = tl.list_id
     where t.env = p_env and t.status = 'sent' and tl.included and tl.send_qty > 0
       and t.sent_at > now() - interval '24 hours'
     order by tl.inventory_id, t.sent_at desc
  )
  select case when a.new_qty > 0 then 'new' else 'earlier' end, a.inventory_id, a.descr, a.bumped, a.new_qty, a.earlier_qty,
         a.orders, a.no_ship, a.oldest, a.oh71, a.ohash,
         ceil(a.bumped * (1 + greatest(p_extra_pct, 0) / 100.0)),
         tr.list_nbr, v_from, v_to
    from agg a left join transit tr on tr.inventory_id = a.inventory_id
   order by case when a.new_qty > 0 then 0 else 1 end, a.bumped desc;
end $$;

-- Save the list: [{inventory_id, send_qty, included}] from the preview the
-- coordinator was looking at (p_cutoff_to = that preview's cut-off, so the
-- next list starts exactly where this one ended). Numbers are re-read from the
-- preview; only send_qty and included come from the page. Not ticked by
-- default: items in transit.
create function public.dispatch_transfer_build(p_env text, p_extra_pct numeric, p_cutoff_to timestamptz, p_lines jsonb, p_note text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_from timestamptz; v_seq int; v_id bigint; v_date date := (now() at time zone 'America/Jamaica')::date;
begin
  perform _dispatch_require('batcher');
  perform pg_advisory_xact_lock(hashtext('transfer:' || p_env));
  if exists (select 1 from transfer_lists where env = p_env and status = 'draft') then
    raise exception 'There''s already a draft transfer list; send or delete it first';
  end if;
  v_from := _dispatch_transfer_from(p_env);
  if p_cutoff_to <= v_from or p_cutoff_to > now() then raise exception 'The preview is out of date; refresh it and build again'; end if;
  select coalesce(max(seq), 0) + 1 into v_seq from transfer_lists where env = p_env and list_date = v_date;
  insert into transfer_lists (env, list_date, seq, list_nbr, cutoff_from, cutoff_to, extra_pct, note, built_name)
  values (p_env, v_date, v_seq, 'TR-' || to_char(v_date, 'MMDD') || '-' || lpad(v_seq::text, 2, '0'),
          v_from, p_cutoff_to, p_extra_pct, nullif(trim(p_note), ''), dispatch_actor_name())
  returning id into v_id;
  insert into transfer_lines (list_id, inventory_id, section, description, bumped, orders, on_hand_71, on_hand_ash, suggested, send_qty, included)
  select v_id, p.inventory_id, p.section, p.description, p.bumped, p.orders, p.on_hand_71, p.on_hand_ash, p.suggested,
         greatest(0, round(coalesce((x->>'send_qty')::numeric, p.suggested))),
         coalesce((x->>'included')::boolean, p.in_transit is null)
    from dispatch_transfer_preview(p_env, p_extra_pct) p
    left join jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) x on x->>'inventory_id' = p.inventory_id;
  return v_id;
end $$;

-- Draft edits: quantity and whether the line goes.
create function public.dispatch_transfer_line_set(p_list_id bigint, p_inventory_id text, p_send_qty numeric, p_included boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _dispatch_require('batcher');
  if not exists (select 1 from transfer_lists where id = p_list_id and status = 'draft') then raise exception 'Only a draft list can be changed'; end if;
  update transfer_lines set send_qty = greatest(0, round(p_send_qty)), included = p_included
   where list_id = p_list_id and inventory_id = p_inventory_id;
end $$;

-- draft -> sent, or delete a draft (its window goes back to the next list).
create function public.dispatch_transfer_action(p_list_id bigint, p_action text)
returns void language plpgsql security definer set search_path = public as $$
declare t transfer_lists;
begin
  perform _dispatch_require('batcher');
  select * into t from transfer_lists where id = p_list_id for update;
  if not found then raise exception 'List not found'; end if;
  if t.status <> 'draft' then raise exception '% has already been sent', t.list_nbr; end if;
  if p_action = 'send' then
    update transfer_lists set status = 'sent', sent_by = auth.uid(), sent_name = dispatch_actor_name(), sent_at = now() where id = p_list_id;
  elsif p_action = 'delete' then
    delete from transfer_lists where id = p_list_id;
  else raise exception 'Unknown action %', p_action;
  end if;
end $$;

revoke all on function public._dispatch_transfer_from(text) from public, anon, authenticated;
revoke all on function public.dispatch_transfer_preview(text, numeric) from public, anon;
revoke all on function public.dispatch_transfer_build(text, numeric, timestamptz, jsonb, text) from public, anon;
revoke all on function public.dispatch_transfer_line_set(bigint, text, numeric, boolean) from public, anon;
revoke all on function public.dispatch_transfer_action(bigint, text) from public, anon;
grant execute on function public.dispatch_transfer_preview(text, numeric) to authenticated;
grant execute on function public.dispatch_transfer_build(text, numeric, timestamptz, jsonb, text) to authenticated;
grant execute on function public.dispatch_transfer_line_set(bigint, text, numeric, boolean) to authenticated;
grant execute on function public.dispatch_transfer_action(bigint, text) to authenticated;

-- The running suggestion is replaced by these lists.
drop function public.dispatch_transfer_suggest(numeric, int, boolean);
