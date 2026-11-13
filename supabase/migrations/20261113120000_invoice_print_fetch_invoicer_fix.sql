-- Fix: Invoicing Clerks ('invoicer') could not print invoices ("Only a supervisor can print invoices").
--
-- 20261105230000_invoicer_role.sql widened invoice_print_fetch to allow 'invoicer'. 20261112160000
-- then recreated that function (to use the current Ship Via on the printed invoice) with the old
-- supervisor/manager-only check, which dropped the invoicer clause again.
--
-- Patch the live definition in place, as the invoicer migration did, so the body (including the
-- Ship Via change) stays exactly as it is. Attributes and grants are kept by the create or replace.
do $$
declare
  fn  text := 'invoice_print_fetch(text[])';
  def text;
  new text;
begin
  def := pg_get_functiondef(fn::regprocedure);
  new := replace(def, 'not (dispatch_has_role(''supervisor'') or dispatch_has_role(''manager'')) then',
                      'not (dispatch_has_role(''supervisor'') or dispatch_has_role(''manager'') or dispatch_has_role(''invoicer'')) then');
  new := replace(new, 'Only a supervisor can print invoices',
                      'Only a supervisor, manager or invoicing clerk can print invoices');
  if new = def then raise exception 'no role check found in %', fn; end if;
  execute new;
end $$;
