-- Dashboard detail (Joel, 2026-10-13): stage timings, needs-attention items, warehouse
-- workload by area, and the monthly tally by trucker. Complements dispatch_ops_summary.
--
--   loads     [{ id, sent_at, trucker_at, locked_at, first_pick_at, last_pick_at, checked_at,
--                confirmed_at, invoiced_at }]            per load on p_date (timing)
--   issues    [{ kind write|confirm|invoice, load_nbr, shipment_nbr, detail, at }]   refused/failed
--   queue     { writes, confirms, invoices, writing, confirming, oldest }            waiting on Acumatica
--   syncs     { shipments_at, lines_at }
--   areas     [{ area, items, picked, short, units, units_picked, loads }]           locked-in loads on p_date
--   pickers   [{ name, items, units, last_at }]                                       who picked on p_date
--   truckers  [{ ship_via, description, loads, shipments, customers, volume, value }] for p_month
create function public.dispatch_ops_detail(p_env text, p_date date, p_month date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare mstart date := date_trunc('month', coalesce(p_month, p_date))::date;
        t jsonb; iss jsonb; q jsonb; sy jsonb; ar jsonb; pk jsonb; tr jsonb;
begin
  if not (dispatch_has_role('manager') or dispatch_has_role('supervisor')) then
    raise exception 'Your account doesn''t have the manager or supervisor role' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', l.id, 'sent_at', l.sent_at, 'trucker_at', l.confirmed_at, 'locked_at', l.applied_at,
      'first_pick_at', (select min(picked_at) from pick_lines where load_id = l.id),
      'last_pick_at',  (select max(picked_at) from pick_lines where load_id = l.id),
      'checked_at', l.checked_at,
      'confirmed_at', (select max(e.created_at) from load_events e where e.load_id = l.id and e.kind = 'check_confirm' and e.outcome = 'confirmed'),
      'invoiced_at', (select max(i.finished_at) from load_shipments ls join shipment_invoicing i on i.env = l.env and i.shipment_nbr = ls.shipment_nbr
                       where ls.load_id = l.id and i.state = 'done'))), '[]'::jsonb)
    into t from loads l where l.env = p_env and l.load_date = p_date;

  select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) into iss from (
    select jsonb_build_object('kind', 'write', 'load_nbr', l.load_nbr, 'shipment_nbr', ls.shipment_nbr,
             'detail', coalesce(ls.result_detail, ls.result), 'at', ls.result_at) x
      from load_shipments ls join loads l on l.id = ls.load_id
     where l.env = p_env and l.load_date = p_date and ls.result in ('refused', 'failed')
    union all
    select jsonb_build_object('kind', 'confirm', 'load_nbr', l.load_nbr, 'shipment_nbr', ls.shipment_nbr,
             'detail', coalesce(ls.check_detail, ls.check_result), 'at', ls.check_at)
      from load_shipments ls join loads l on l.id = ls.load_id
     where l.env = p_env and l.load_date = p_date and ls.check_result in ('refused', 'failed')
    union all
    select jsonb_build_object('kind', 'invoice', 'load_nbr', l.load_nbr, 'shipment_nbr', i.shipment_nbr,
             'detail', coalesce(i.detail, i.state), 'at', i.updated_at)
      from shipment_invoicing i
      left join load_shipments ls on ls.env = i.env and ls.shipment_nbr = i.shipment_nbr
      left join loads l on l.id = ls.load_id
     where i.env = p_env and i.state in ('refused', 'failed') and i.updated_at > now() - interval '1 day'
    limit 50) u;

  select jsonb_build_object(
    'writes',   (select count(*) from loads where env = p_env and write_requested_at is not null),
    'confirms', (select count(*) from loads where env = p_env and confirm_requested_at is not null),
    'invoices', (select count(*) from shipment_invoicing where env = p_env and state in ('queued', 'running')),
    'writing',    (select count(*) from loads where env = p_env and status = 'writing'),
    'confirming', (select count(*) from loads where env = p_env and check_status = 'confirming'),
    'oldest', (select min(x) from (select write_requested_at x from loads where env = p_env and write_requested_at is not null
                                   union all select confirm_requested_at from loads where env = p_env and confirm_requested_at is not null
                                   union all select requested_at from shipment_invoicing where env = p_env and state = 'queued') z))
    into q;

  select jsonb_build_object(
    'shipments_at', (select max(synced_at) from _dispatch_shipments(p_env)),
    'lines_at',     (select max(synced_at) from shipment_lines where env = p_env)) into sy;

  select coalesce(jsonb_agg(x order by (x->>'area')::int), '[]'::jsonb) into ar from (
    select jsonb_build_object('area', p.area, 'items', count(*), 'picked', count(*) filter (where p.picked_qty is not null),
             'short', count(*) filter (where p.picked_qty is not null and p.picked_qty < p.required),
             'units', sum(p.required), 'units_picked', coalesce(sum(p.picked_qty), 0), 'loads', count(distinct l.id)) x
      from loads l, lateral dispatch_pick_list(l.id) p
     where l.env = p_env and l.load_date = p_date and l.status in ('done', 'partial')
     group by p.area) a;

  select coalesce(jsonb_agg(x order by (x->>'items')::int desc), '[]'::jsonb) into pk from (
    select jsonb_build_object('name', coalesce(pl.picker_name, 'Unknown'), 'items', count(*), 'units', sum(pl.picked_qty), 'last_at', max(pl.picked_at)) x
      from pick_lines pl join loads l on l.id = pl.load_id
     where l.env = p_env and l.load_date = p_date group by pl.picker_name) a;

  with m as (
    select s.ship_via, count(*) ships, count(distinct s.customer_id) custs,
           coalesce(sum(s.shipped_volume), 0) vol, coalesce(sum(s.shipment_value), 0) val
      from _dispatch_shipments(p_env) s
     where s.shipment_date >= mstart and s.shipment_date < mstart + interval '1 month' and s.operation = 'Issue'
       and coalesce(s.ship_via, '') <> '' and s.ship_via not ilike 'BATCH%' and s.status <> 'Cancelled'
     group by s.ship_via),
  n as (select l.ship_via, count(*) loads from loads l
         where l.env = p_env and l.load_date >= mstart and l.load_date < mstart + interval '1 month' and l.status in ('done', 'partial')
         group by l.ship_via)
  select coalesce(jsonb_agg(jsonb_build_object('ship_via', m.ship_via, 'description', c.description, 'loads', coalesce(n.loads, 0),
           'shipments', m.ships, 'customers', m.custs, 'volume', m.vol, 'value', m.val) order by m.ships desc, m.ship_via), '[]'::jsonb)
    into tr from m left join n on n.ship_via = m.ship_via left join ship_via_codes c on c.ship_via = m.ship_via;

  return jsonb_build_object('loads', t, 'issues', iss, 'queue', q, 'syncs', sy, 'areas', ar, 'pickers', pk, 'truckers', tr);
end $$;
revoke all on function public.dispatch_ops_detail(text, date, date) from public, anon;
grant execute on function public.dispatch_ops_detail(text, date, date) to authenticated;
