-- Furthest town on the trucker check-off sheets. zone_distance ranks shipping zones by approximate road km
-- from the Kingston yard; lm_check_sheet returns the furthest zone on the load as 'farthest'. Zones with no
-- row (R01-R23 city routes, EMPLOYEES, PROMOTIONS...) are treated as local and never win. Distances are
-- estimates: edit the km column to re-rank. Zone names must match customers.shipping_zone exactly.
create table if not exists public.zone_distance (
  zone  text primary key,
  label text not null,
  km    int  not null
);
alter table public.zone_distance enable row level security;
drop policy if exists zone_distance_read on public.zone_distance;
create policy zone_distance_read on public.zone_distance for select to authenticated using (dispatch_has_role());
revoke all on public.zone_distance from anon;
grant select on public.zone_distance to authenticated;

insert into public.zone_distance (zone, label, km) values
  ('KINGSTON','Kingston',0),('KINGSTONOFFICE','Kingston',0),('KINGSTONROUTE','Kingston',0),('DOWNTOWN','Kingston',0),
  ('PAPINE','Papine',8),('HARBOUR VIEW','Harbour View',12),('PALISADOES','Palisadoes',15),('TEMPLE HALL','Temple Hall',12),
  ('ABOVE ROCKS','Above Rocks',20),('GOLDENSPRING','Golden Spring',15),('BULL BAY','Bull Bay',15),('STONYHILL','Stony Hill',15),
  ('PORTMORE','Portmore',18),('SPANISHTOWN','Spanish Town',22),('STCATHERINE','St Catherine',25),('LAWRENCE TAVERN','Lawrence Tavern',25),
  ('GLENGOFFE','Glengoffe',30),('GUYS HILL','Guys Hill',32),('BOG WALK','Bog Walk',35),('KITSON TOWN','Kitson Town',35),
  ('YALLAHS','Yallahs',35),('OLDHARBOUR','Old Harbour',40),('LINSTEAD','Linstead',38),('EWARTON','Ewarton',45),
  ('MORANTBAY','Morant Bay',50),('STTHOMAS','St Thomas',50),('SEAFORTH','Seaforth',55),('ALBION','Albion',60),
  ('CLARENDON','Clarendon',60),('MAYPEN','May Pen',60),('PORTMORANT','Port Morant',65),('MONEAGUE','Moneague',70),
  ('FRANKFIELD','Frankfield',70),('LIONELTOWN','Lionel Town',70),('PALMERS CROSS','Palmers Cross',70),('ANNOTTOBAY','Annotto Bay',70),
  ('HIGHGATE','Highgate',75),('BUFFBAY','Buff Bay',80),('PORTMARIA','Port Maria',80),('STMARY','St Mary',80),('KELLITS','Kellits',80),
  ('CLARKSTOWN','Clarkstown',85),('CHAPLETON','Chapleton',85),('CLAREMONT','Claremont',85),('ORACABESSA','Oracabessa',85),
  ('TOWER ISLE','Tower Isle',90),('SPALDING','Spalding',90),('CROFTS HILLS','Crofts Hills',90),('GAYLE','Gayle',90),
  ('PORTANTONIO','Port Antonio',100),('OCHORIOS','Ocho Rios',100),('MANDEVILLE','Mandeville',100),('CHRISTIANA','Christiana',105),
  ('STANNSBAY','St Ann''s Bay',110),('ALLIGATOR POND','Alligator Pond',115),('ALEXANDRIA','Alexandria',115),('RUNAWAYBAY','Runaway Bay',120),
  ('STEER TOWN','Steer Town',120),('BROWNSTOWN','Brown''s Town',125),('DISCOVERYBAY','Discovery Bay',135),('SANTACRUZ','Santa Cruz',135),
  ('TRELAWNY','Trelawny',150),('JUNCTION','Junction',150),('BALACLAVA','Balaclava',150),('MOUNTAINSIDE','Mountainside',150),
  ('STELIZABETH','St Elizabeth',150),('FALMOUTH','Falmouth',160),('LACOVIA','Lacovia',160),('NAIN','Nain',160),('MAGOTTY','Magotty',165),
  ('BRAES RIVER','Braes River',170),('BLACKRIVER','Black River',175),('SOUTHFIELD','Southfield',180),('MOBAY','Montego Bay',190),
  ('MOBAYHOUSE','Montego Bay',190),('NEWMARKET','Newmarket',190),('TREASURE BEACH','Treasure Beach',190),('ANCHOVY','Anchovy',200),
  ('WHITEHOUSE','Whitehouse',200),('WHITEHOUSEDARL','Whitehouse',200),('BETHEL TOWN','Bethel Town',215),('DARLISTAN','Darliston',215),
  ('HOPEWELL','Hopewell',215),('SANDY BAY','Sandy Bay',225),('GREEN ISLAND','Green Island',230),('SAV','Savanna-la-Mar',230),
  ('SAVANNALAMAR','Savanna-la-Mar',230),('LUCEA','Lucea',240),('PETERSIELD','Petersfield',245),('SHEFFIELD','Sheffield',245),
  ('GRANGEHILL','Grange Hill',250),('LITTLE LONDON','Little London',255),('ORANGE BAY','Orange Bay',260),('NEGRIL','Negril',270)
on conflict (zone) do nothing;

create or replace function public.lm_check_sheet(p_load_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l loads;
begin
  if auth.uid() is null or not dispatch_has_role() then
    raise exception 'Your account doesn''t have a dispatch role' using errcode = '42501';
  end if;
  select * into l from loads where id = p_load_id;
  if not found then raise exception 'Load not found'; end if;
  return jsonb_build_object(
    'load_nbr', l.load_nbr, 'load_date', l.load_date, 'wave', l.wave, 'env', l.env,
    'ship_via', l.ship_via, 'trucker', (select description from ship_via_codes where ship_via = l.ship_via),
    'truck_type', l.truck_type, 'check_status', l.check_status,
    'farthest', (select jsonb_build_object('zone', d.zone, 'label', d.label, 'km', d.km)
                   from _lm_stop_rows(p_load_id) r join zone_distance d on d.zone = upper(btrim(r.zone))
                  order by d.km desc, d.zone limit 1),
    'stops', coalesce((
      select jsonb_agg(jsonb_build_object(
               'seq', r.seq, 'customer_id', r.customer_id, 'customer_name', r.customer_name,
               'address', r.address, 'city', r.city, 'phone', r.phone, 'zone', r.zone,
               'shipments', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'shipment_nbr', ls.shipment_nbr,
                          'invoice_nbr', (select i.invoice_nbr from lm_stop_invoices i join lm_stops st on st.id = i.stop_id
                                           where st.load_id = l.id and i.shipment_nbr = ls.shipment_nbr limit 1),
                          'lines', (select coalesce(jsonb_agg(jsonb_build_object(
                                             'line_nbr', sl.line_nbr, 'inventory_id', sl.inventory_id, 'description', sl.description,
                                             'uom', sl.uom, 'qty', coalesce(cl.final_qty, sl.shipped_qty)) order by sl.line_nbr), '[]'::jsonb)
                                      from shipment_lines sl
                                      left join check_lines cl on cl.load_id = l.id and cl.shipment_nbr = sl.shipment_nbr and cl.line_nbr = sl.line_nbr
                                     where sl.env = l.env and sl.shipment_nbr = ls.shipment_nbr
                                       and coalesce(cl.final_qty, sl.shipped_qty) > 0)
                        ) order by ls.shipment_nbr), '[]'::jsonb)
                   from load_shipments ls
                   join lateral (select * from _dispatch_shipments(l.env) x where x.shipment_nbr = ls.shipment_nbr) s on true
                  where ls.load_id = l.id and coalesce(s.customer_id, '?') = r.customer_id))
             order by r.seq)
        from _lm_stop_rows(p_load_id) r), '[]'::jsonb));
end $$;

revoke all on function public.lm_check_sheet(bigint) from public, anon;
grant execute on function public.lm_check_sheet(bigint) to authenticated;

-- Rollback (by hand): restore lm_check_sheet from 20261102110000_lm_check_sheet.sql; drop table public.zone_distance;
