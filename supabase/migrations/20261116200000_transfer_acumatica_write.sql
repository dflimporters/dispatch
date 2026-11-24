-- 2026-11-16. Record the Acumatica Transfer written from a sent transfer list (edge function acu-transfer-write).
-- The function writes the TR as a request ON HOLD (never released) and stores the result here. A list is written once:
-- acu_state 'creating' is the lock; 'failed' can be retried; 'created' is final.
-- Rollback: drop the five columns.
alter table public.transfer_lists
  add column acu_state text check (acu_state in ('creating', 'created', 'failed')),
  add column acu_ref   text,
  add column acu_error text,
  add column acu_at    timestamptz,
  add column acu_name  text;
