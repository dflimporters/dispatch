-- Invoicing Clerk ('invoicer') also gets the Load sheets page: view and print sheets, and build a load
-- from an invoice. Reassigning loads stays with clerk / supervisor / manager (_lm_can_reassign).
-- Only what that page reads or calls is widened, not lm_staff() (which also feeds the Control Tower
-- and Returns tables).

drop policy lm_loads_read on public.lm_loads;
create policy lm_loads_read on public.lm_loads for select to authenticated
  using (public.lm_staff() or public.dispatch_has_role('invoicer'));

do $$
declare
  fn  text;
  def text;
  new text;
begin
  foreach fn in array array['lm_invoice_search(text)', 'lm_build_invoice_load(text, text[])'] loop
    def := pg_get_functiondef(fn::regprocedure);
    new := replace(def, 'not lm_staff() then', 'not (lm_staff() or dispatch_has_role(''invoicer'')) then');
    if new = def then raise exception 'no lm_staff check found in %', fn; end if;
    execute new;
  end loop;
end $$;
