-- Picker / checker (Joel, 2026-11-23): each item shows which customers on the load are getting it.
-- dispatch_pick_bundle gains 'customers': one row per load + item with [{name, qty}] per customer.
-- Clients that don't know the key ignore it; the pages show no names until this is applied.

create or replace function public.dispatch_pick_bundle(p_load_ids bigint[], p_with_checks boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not dispatch_has_role() then raise exception 'Your account has no dispatch role' using errcode = '42501'; end if;
  return jsonb_build_object(
    'picks',  coalesce((select jsonb_agg(to_jsonb(x) || jsonb_build_object('load_id', l.id))
                          from unnest(p_load_ids) as l(id), lateral dispatch_pick_list(l.id) x), '[]'::jsonb),
    'done',   coalesce((select jsonb_agg(to_jsonb(s)) from pick_area_status s where s.load_id = any(p_load_ids)), '[]'::jsonb),
    'staged', coalesce((select jsonb_agg(to_jsonb(s)) from stage_area_status s where s.load_id = any(p_load_ids)), '[]'::jsonb),
    'checks', case when p_with_checks
                   then coalesce((select jsonb_agg(to_jsonb(c)) from check_lines c where c.load_id = any(p_load_ids)), '[]'::jsonb)
                   else '[]'::jsonb end,
    'items',  case when p_with_checks
                   then coalesce((select jsonb_agg(to_jsonb(c)) from check_items c where c.load_id = any(p_load_ids)), '[]'::jsonb)
                   else '[]'::jsonb end,
    'customers', coalesce((
        select jsonb_agg(jsonb_build_object('load_id', t.load_id, 'inventory_id', t.inventory_id, 'list', t.list))
          from (select c.load_id, c.inventory_id,
                       jsonb_agg(jsonb_build_object('name', c.name, 'qty', c.qty) order by c.name) as list
                  from (select l.id as load_id, sl.inventory_id,
                               coalesce(max(s.customer_name), max(s.customer_id), '?') as name, sum(sl.shipped_qty) as qty
                          from loads l
                          join load_shipments ls on ls.load_id = l.id
                          join shipment_lines sl on sl.env = l.env and sl.shipment_nbr = ls.shipment_nbr and sl.shipped_qty > 0
                          left join _dispatch_shipments(l.env) s on s.shipment_nbr = ls.shipment_nbr
                         where l.id = any(p_load_ids)
                         group by l.id, sl.inventory_id, coalesce(s.customer_id, s.customer_name, ls.shipment_nbr)) c
                 group by c.load_id, c.inventory_id) t), '[]'::jsonb));
end $$;

-- Rollback: re-run the dispatch_pick_bundle definition from 20261024090000_checker_sheet.sql.
