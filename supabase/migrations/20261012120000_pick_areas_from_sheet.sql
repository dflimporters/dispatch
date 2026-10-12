-- Pick areas from the warehouse manager's sheet (picking_areas.xlsx, 2026-10-12).
-- The sheet maps 1,453 items to zones 1-7 (12 items have no zone and stay
-- Unassigned), so areas widen from 1-4 to 1-7. The per-item mapping replaces the
-- placeholder item-class mapping, which is emptied; pick_area_of() now resolves
-- from pick_area_items alone for anything in the sheet. Items not in the sheet show as Unassigned.
--
-- Applied directly via the Supabase MCP with the item rows inline (a VALUES list of
-- (inventory_id, zone) read from the sheet's Data tab, columns A and C). Re-running
-- means re-importing the sheet, so the rows aren't repeated here.

alter table public.pick_areas drop constraint if exists pick_areas_area_check;
alter table public.pick_areas add constraint pick_areas_area_check check (area between 1 and 7);
insert into public.pick_areas values (5, 'Area 5'), (6, 'Area 6'), (7, 'Area 7') on conflict do nothing;
delete from public.pick_area_classes;
delete from public.pick_area_items;
-- insert into public.pick_area_items (inventory_id, area, source)
--   select v.i, v.z, 'picking_areas.xlsx 2026-10-01' from (values ...) v(i, z);
comment on table public.pick_area_classes is 'Unused: item classes are no longer mapped; pick_area_items (per item) is the source.';
