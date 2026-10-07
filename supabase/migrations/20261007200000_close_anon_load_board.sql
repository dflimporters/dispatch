-- The old anon load board (index.html) is gone; it's now a signed-in landing
-- page. Close the anonymous access it needed. The signed-in pages keep their
-- own read policies (shipments_read_authenticated, truck_types_read_authenticated).
-- Sync jobs write with the service role and aren't affected.

drop policy if exists shipments_read_anon on public.shipments;
drop policy if exists truck_types_read_anon on public.truck_types;

-- ship_via_codes was readable by anon and authenticated in one policy.
drop policy if exists ship_via_codes_read on public.ship_via_codes;
create policy ship_via_codes_read on public.ship_via_codes
  for select to authenticated using (true);

-- Old BATCH-placeholder flow: nothing reads or writes these any more. With RLS
-- on and no policies they're locked to the service role. Drop the tables after
-- go-live once nobody needs the history.
drop policy if exists batch_assignments_insert_test on public.batch_assignments;
drop policy if exists batch_assignments_read_test   on public.batch_assignments;
drop policy if exists batch_assignments_update_test on public.batch_assignments;
drop policy if exists batch_events_insert_test      on public.batch_events;
drop policy if exists batch_events_read_test        on public.batch_events;
