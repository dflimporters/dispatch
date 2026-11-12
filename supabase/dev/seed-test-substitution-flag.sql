-- TEST ONLY. Throwaway data for trying the substitution feature on the Invoicing page (Test mode).
-- Load 609 (L-1211-01, env 'test') already exists with shipment 256211 on it. This marks the load as finished by the
-- checker and raises a "substitution needed" flag on item 10003691 for the customer on that shipment, the way the
-- checker would. Then, on Invoicing in Test mode, "Substitute..." appears on that row.
-- Safe to run twice. To clean up afterwards see the bottom of this file.

with l as (
  update loads set checker_done_at = coalesce(checker_done_at, now()), checker_done_name = coalesce(checker_done_name, 'THROWAWAY test')
   where id = 609 and env = 'test' returning id
)
insert into check_items (load_id, inventory_id, checked_qty, confirmed, checker_name, checked_at, sub_needed, sub_note, sub_by_name, sub_at, sub_context)
select 609, '10003691', 0, true, 'THROWAWAY test', now(), true, 'THROWAWAY: test flag for the substitution build', 'THROWAWAY test', now(),
  jsonb_build_object('description', 'Eco-Valu Bagasse Burger Box (8x50)', 'uom', 'CASE', 'required', 2,
    'lines', jsonb_build_array(jsonb_build_object('shipment', '256211', 'customer_id', 'C000009615',
      'customer', (select customer_name from customers where customer_id = 'C000009615'),
      'order_type', 'SO', 'order_nbr', '189636', 'order_line', 1, 'qty', 2, 'unit_price', 6552.07)))
from l
on conflict (load_id, inventory_id) do update set sub_needed = true, sub_resolved_at = null, sub_context = excluded.sub_context
returning load_id, inventory_id, sub_needed;

-- Cleanup when testing is finished (test rows only):
-- delete from substitutions where env = 'test' and load_id = 609;
-- delete from check_items where load_id = 609;
-- delete from load_shipments where env = 'test' and load_id = 609;
-- delete from loads where id = 609 and env = 'test';
-- delete from shipment_lines where env = 'test' and shipment_nbr = '256211';
-- delete from shipments_test where shipment_nbr = '256211';
