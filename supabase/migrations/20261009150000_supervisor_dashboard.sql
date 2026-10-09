-- Supervisor invoicing screen + operations dashboard (Joel's notes, 2026-10-09).
--
-- 1. Roles: 'supervisor' (bulk-converts confirmed shipments to invoices) and
--    'manager' (Operations Manager: read-only dashboard). A supervisor also
--    sees the dashboard.
-- 2. shipment_invoicing: the queue + result of "Prepare Invoice" per shipment.
--    dispatch-acu "invoice_request" marks rows queued; the drain (same lease and
--    pacing as the other Acumatica writes) works through them and records the
--    result. Releasing the invoice stays with Accounts.
-- 3. dispatch_ops_summary(env, date): everything the dashboard shows, in one call.

alter table public.dispatch_roles drop constraint dispatch_roles_role_check;
alter table public.dispatch_roles add constraint dispatch_roles_role_check
  check (role in ('batcher', 'clerk', 'picker', 'checker', 'supervisor', 'manager'));

create table public.shipment_invoicing (
  env           text not null check (env in ('live', 'test')),
  shipment_nbr  text not null,
  state         text not null check (state in ('queued', 'running', 'done', 'refused', 'failed')),
  detail        text,
  requested_by  text,
  requested_at  timestamptz not null default now(),
  finished_at   timestamptz,
  updated_at    timestamptz not null default now(),   -- heartbeat while running
  primary key (env, shipment_nbr)
);
create index shipment_invoicing_queue on public.shipment_invoicing (env, requested_at) where state = 'queued';
alter table public.shipment_invoicing enable row level security;
create policy shipment_invoicing_read on public.shipment_invoicing for select to authenticated
  using (public.dispatch_has_role('supervisor') or public.dispatch_has_role('manager'));
revoke all on public.shipment_invoicing from anon;
revoke insert, update, delete, truncate on public.shipment_invoicing from authenticated;

-- Dashboard. One jsonb:
--   orders    { by_status: [{status, orders}], new_today, needs_attention }   (production orders)
--   shipments { by_status: [{status, n}] for the day, older_active }
--   loads     [{ id, load_nbr, wave, truck_type, ship_via, status, check_status, shipments, confirmed,
--                invoiced, items, picked, short, areas, areas_done, queued }]
--   free      shipments for the day not on any load
create function public.dispatch_ops_summary(p_env text, p_date date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare o jsonb; s jsonb; ld jsonb; f int;
begin
  if not (dispatch_has_role('manager') or dispatch_has_role('supervisor')) then
    raise exception 'Your account doesn''t have the manager or supervisor role' using errcode = '42501';
  end if;

  -- Sales orders (so_ordered_items is production, one row per order line).
  select jsonb_build_object(
    'by_status', coalesce((select jsonb_agg(jsonb_build_object('status', order_status, 'orders', n) order by n desc)
       from (select order_status, count(distinct order_nbr) n from so_ordered_items
              where order_type = 'SO' and (order_status not in ('Completed', 'Canceled') or order_date = p_date)
              group by order_status) t), '[]'::jsonb),
    'new_today', (select count(distinct order_nbr) from so_ordered_items where order_type = 'SO' and order_date = p_date),
    'completed_today', (select count(distinct order_nbr) from so_ordered_items where order_type = 'SO' and order_status = 'Completed' and order_date = p_date))
  into o;

  select jsonb_build_object(
    'by_status', coalesce((select jsonb_agg(jsonb_build_object('status', status, 'n', n) order by n desc)
       from (select status, count(*) n from _dispatch_shipments(p_env) where shipment_date = p_date and operation = 'Issue' group by status) t), '[]'::jsonb),
    'older_active', (select count(*) from _dispatch_shipments(p_env)
                      where shipment_date < p_date and operation = 'Issue' and status in ('On Hold', 'Open', 'Confirmed')))
  into s;

  select coalesce(jsonb_agg(x order by x->>'wave', (x->>'seq')::int), '[]'::jsonb) into ld from (
    select jsonb_build_object(
      'id', l.id, 'load_nbr', l.load_nbr, 'wave', l.wave, 'seq', l.seq, 'truck_type', l.truck_type, 'ship_via', l.ship_via,
      'status', l.status, 'check_status', l.check_status,
      'queued', (l.write_requested_at is not null or l.confirm_requested_at is not null),
      'shipments', (select count(*) from load_shipments ls where ls.load_id = l.id),
      'confirmed', (select count(*) from load_shipments ls join _dispatch_shipments(p_env) sh on sh.shipment_nbr = ls.shipment_nbr
                     where ls.load_id = l.id and sh.status in ('Confirmed', 'Invoiced', 'Completed')),
      'invoiced', (select count(*) from load_shipments ls join _dispatch_shipments(p_env) sh on sh.shipment_nbr = ls.shipment_nbr
                    where ls.load_id = l.id and sh.status in ('Invoiced', 'Completed')),
      'invoice_queued', (select count(*) from load_shipments ls join shipment_invoicing i on i.env = l.env and i.shipment_nbr = ls.shipment_nbr
                          where ls.load_id = l.id and i.state in ('queued', 'running')),
      'items', (select count(*) from dispatch_pick_list(l.id)),
      'picked', (select count(*) from dispatch_pick_list(l.id) p where p.picked_qty is not null),
      'short', (select count(*) from dispatch_pick_list(l.id) p where p.picked_qty is not null and p.picked_qty < p.required),
      'areas', (select count(distinct p.area) from dispatch_pick_list(l.id) p),
      'areas_done', (select count(*) from pick_area_status a where a.load_id = l.id)) x
    from loads l where l.env = p_env and l.load_date = p_date) t;

  select count(*) into f from _dispatch_shipments(p_env) sh
   where sh.shipment_date = p_date and sh.operation = 'Issue' and sh.status in ('On Hold', 'Open')
     and not exists (select 1 from load_shipments ls where ls.env = p_env and ls.shipment_nbr = sh.shipment_nbr);

  return jsonb_build_object('orders', o, 'shipments', s, 'loads', ld, 'free', f);
end $$;
revoke all on function public.dispatch_ops_summary(text, date) from public, anon;
grant execute on function public.dispatch_ops_summary(text, date) to authenticated;

-- 4. Active admins (profiles.role = 'admin') get every dispatch role, so they can
--    see and do everything. Anyone made an admin later needs rows added.
insert into public.dispatch_roles (user_id, role)
select p.id, r.role from public.profiles p
  cross join (values ('batcher'), ('clerk'), ('picker'), ('checker'), ('supervisor'), ('manager')) r(role)
 where p.role = 'admin' and p.active
on conflict do nothing;
