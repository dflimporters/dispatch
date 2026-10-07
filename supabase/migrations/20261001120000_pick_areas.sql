-- Pick areas: which warehouse area (1-4) picks each item.
--
-- PLACEHOLDER until the warehouse manager's mapping arrives. For now every
-- item class goes to an area (pick_area_classes). The real mapping will go
-- per item into pick_area_items, which wins over the class. After the
-- warehouse move this switches to Acumatica Warehouse Locations.
--
-- An item whose class isn't listed and that has no override resolves to
-- null, shown as "Unassigned" on the picklist, so new SKUs are never silently
-- dropped from a pick.

create table public.pick_areas (
  area  int  primary key check (area between 1 and 4),
  name  text not null
);
insert into public.pick_areas values (1, 'Area 1'), (2, 'Area 2'), (3, 'Area 3'), (4, 'Area 4');

create table public.pick_area_classes (
  item_class text primary key,
  area       int  not null references public.pick_areas(area),
  source     text not null default 'placeholder'
);

create table public.pick_area_items (
  inventory_id text primary key,
  area         int  not null references public.pick_areas(area),
  source       text not null default 'warehouse',
  updated_at   timestamptz not null default now()
);

-- Placeholder split by item class (roughly by product family).
insert into public.pick_area_classes (item_class, area) values
  -- Area 1: mezzanine smallwares and tableware
  ('MEZ', 1), ('MEZSMALLWA', 1), ('MEZAMENITY', 1), ('MEZPORCELA', 1), ('MEZCUTLERY', 1),
  ('MEZGLASSWA', 1), ('MEZLINEN', 1), ('MEZPOLYCAR', 1), ('MEZMELAMIN', 1), ('MEZEQUIPME', 1),
  -- Area 2: plastics, foil, wrap, bags, paper
  ('PLASTIC', 2), ('CLEARPACK', 2), ('FOIL', 2), ('PLSWRAP', 2), ('GARBAGEBAG', 2),
  ('PAPER', 2), ('PROCESSING', 2),
  -- Area 3: eco range, food service, food and drink
  ('ECOCUP', 3), ('ECOBOX', 3), ('ECOBAG', 3), ('ECOSTRAW', 3), ('FOODSERV', 3),
  ('FOODSUP', 3), ('BEVERAGES', 3), ('SALT', 3),
  -- Area 4: stationery, household, furniture, PPE, everything else
  ('STAT', 4), ('STATROLL', 4), ('STATENV', 4), ('STATLABEL', 4), ('STATFORM', 4),
  ('HOUSEHOLD', 4), ('FURN', 4), ('PPE', 4), ('WIPES', 4), ('SALES', 4), ('HOSP', 4);

-- Item override first, then its class, else null (Unassigned).
create function public.pick_area_of(p_inventory_id text) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select area from pick_area_items where inventory_id = p_inventory_id),
    (select c.area from stock_items_raw s join pick_area_classes c on c.item_class = s.item_class
      where s.inventory_id = p_inventory_id limit 1));
$$;

alter table public.pick_areas        enable row level security;
alter table public.pick_area_classes enable row level security;
alter table public.pick_area_items   enable row level security;
create policy pick_areas_read        on public.pick_areas        for select to authenticated using (public.dispatch_has_role());
create policy pick_area_classes_read on public.pick_area_classes for select to authenticated using (public.dispatch_has_role());
create policy pick_area_items_read   on public.pick_area_items   for select to authenticated using (public.dispatch_has_role());
revoke all on public.pick_areas, public.pick_area_classes, public.pick_area_items from anon;
revoke insert, update, delete, truncate on public.pick_areas, public.pick_area_classes, public.pick_area_items from authenticated;
revoke execute on function public.pick_area_of(text) from anon, public;
grant execute on function public.pick_area_of(text) to authenticated;

comment on table public.pick_area_classes is 'PLACEHOLDER item class -> pick area until the warehouse manager''s mapping arrives.';
comment on table public.pick_area_items   is 'Per-item pick area (warehouse manager''s mapping). Wins over pick_area_classes.';
