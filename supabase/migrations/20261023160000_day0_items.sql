-- Day 0 plan: the full item list for the pallet-size editor (Transfer tab). One row per item ever
-- ordered, from the latest order line: description, class, case volume, stock at 71, pallet size
-- (null when none is set) and the last order date, so items that are not on this run's transfer
-- can be sized too.
create or replace function public.dispatch_day0_items()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not dispatch_has_role('batcher') then
    raise exception 'Your account doesn''t have the coordinator role' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('item', x.inventory_id, 'descr', x.d, 'cls', x.c, 'vol', coalesce(x.v, 0),
                                        'oh', coalesce(x.oh, 0), 'pallet', p.cases_per_pallet, 'last', x.l))
      from (select distinct on (i.inventory_id) i.inventory_id, i.line_description d, i.item_class c, i.volume v,
                   i.qty_on_hand_71 oh, max(i.order_date) over (partition by i.inventory_id) l
              from so_ordered_items i
             where i.order_type = 'SO' and i.inventory_id is not null
             order by i.inventory_id, i.order_date desc) x
      left join item_pallet_sizes p on p.inventory_id = x.inventory_id
  ), '[]'::jsonb);
end $$;
revoke all on function public.dispatch_day0_items() from public, anon;
grant execute on function public.dispatch_day0_items() to authenticated;
