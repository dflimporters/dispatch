-- Loads are built on the portal only (Joel, 2026-11-10). A shipment that already has a Ship Via set in
-- Acumatica can now be put on a portal load: the confirm writeback (dispatch-acu) snapshots the current
-- Ship Via as ship_via_before and replaces it with the load's trucker, refusing only if it changed in
-- Acumatica after the load was confirmed. Still refused: not Open/On Hold, returns (RC), already on a load.

create or replace function public._dispatch_check_free(p_env text, p_nbrs text[]) returns void
language plpgsql stable security definer set search_path = public as $$
declare bad text; taken text;
begin
  select string_agg(n, ', ') into bad
    from unnest(p_nbrs) n
   where not exists (
     select 1 from _dispatch_shipments(p_env) s
      where s.shipment_nbr = n and s.operation = 'Issue' and coalesce(s.order_type, '') <> 'RC'
        and s.status in ('On Hold', 'Open'));
  if bad is not null then
    raise exception 'Can''t load these (not open, or not found): %', bad;
  end if;
  select string_agg(ls.shipment_nbr || ' (' || l.load_nbr || ')', ', ') into taken
    from load_shipments ls join loads l on l.id = ls.load_id
   where ls.env = p_env and ls.shipment_nbr = any (p_nbrs);
  if taken is not null then raise exception 'Already on a load: %', taken; end if;
end $$;
