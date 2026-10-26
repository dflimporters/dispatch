-- A shipment with nothing left to ship after the checker's counts is "skipped": dispatch-acu leaves it
-- untouched in Acumatica and it no longer holds the rest of the load back from invoicing.
alter table public.load_shipments drop constraint load_shipments_check_result_check;
alter table public.load_shipments add constraint load_shipments_check_result_check
  check (check_result in ('applied', 'refused', 'failed', 'skipped'));

-- Rollback (by hand): update load_shipments set check_result = 'refused' where check_result = 'skipped';
-- then restore the original constraint without 'skipped'.
