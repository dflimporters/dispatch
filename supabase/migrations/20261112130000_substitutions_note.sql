-- 2026-11-12. A finished substitution can carry a warning (substitutions.note): found on the first TEST run, where the
-- substitute SO was for 2 but only 1 was available, so Acumatica (Cancel Remainder) shipped 1 and the row still read as done.
-- dispatch-sub now lowers qty to what shipped and says so here; the Invoicing panel shows it.
-- Rollback: alter table public.substitutions drop column note;

alter table public.substitutions add column note text;
comment on column public.substitutions.note is 'Warning shown with a finished row, e.g. fewer units shipped than asked for';
