-- Invoicing Clerk ('invoicer'): the Invoicing page only. Can read the invoicing tables, print and
-- void invoices, save the confirm quantities, resolve substitutions, and (through dispatch-acu)
-- confirm loads and prepare invoices. Everything else stays with supervisor / manager.
-- Invited: shaniqued@ and tiffany@dflimporters.com (Joel, 2026-11-05).

alter table public.dispatch_roles drop constraint dispatch_roles_role_check;
alter table public.dispatch_roles add constraint dispatch_roles_role_check
  check (role in ('batcher', 'clerk', 'picker', 'checker', 'supervisor', 'manager', 'security', 'admin', 'invoicer'));
alter table public.dispatch_role_invites drop constraint dispatch_role_invites_role_check;
alter table public.dispatch_role_invites add constraint dispatch_role_invites_role_check
  check (role in ('batcher', 'clerk', 'picker', 'checker', 'supervisor', 'manager', 'security', 'admin', 'invoicer'));

-- Read access to the three invoicing tables.
drop policy invoice_prints_read on public.invoice_prints;
create policy invoice_prints_read on public.invoice_prints for select to authenticated
  using (public.dispatch_has_role('supervisor') or public.dispatch_has_role('manager')
         or public.dispatch_has_role('invoicer') or public._admin_ok());
drop policy invoice_load_marks_read on public.invoice_load_marks;
create policy invoice_load_marks_read on public.invoice_load_marks for select to authenticated
  using (public.dispatch_has_role('supervisor') or public.dispatch_has_role('manager')
         or public.dispatch_has_role('invoicer') or public._admin_ok());
drop policy shipment_invoicing_read on public.shipment_invoicing;
create policy shipment_invoicing_read on public.shipment_invoicing for select to authenticated
  using (public.dispatch_has_role('supervisor') or public.dispatch_has_role('manager')
         or public.dispatch_has_role('invoicer'));

-- The invoice functions check the role inline; widen each check in place (attributes and grants stay).
do $$
declare
  fn  text;
  def text;
  new text;
begin
  foreach fn in array array[
    'invoice_print_record(text, jsonb, text)', 'invoice_print_void(bigint[], text)',
    'invoice_load_mark_printed(text, bigint, boolean)', 'invoice_print_so_headers(text[])',
    'invoice_print_fetch(text[])', 'invoice_print_missing(text[])', 'invoice_print_for_shipments(jsonb)'
  ] loop
    def := pg_get_functiondef(fn::regprocedure);
    new := replace(def, 'not dispatch_has_role(''supervisor'') then',
                        'not (dispatch_has_role(''supervisor'') or dispatch_has_role(''invoicer'')) then');
    new := replace(new, 'not (dispatch_has_role(''supervisor'') or dispatch_has_role(''manager'')) then',
                        'not (dispatch_has_role(''supervisor'') or dispatch_has_role(''manager'') or dispatch_has_role(''invoicer'')) then');
    if new = def then raise exception 'no role check found in %', fn; end if;
    execute new;
  end loop;

  -- The three Invoicing-page functions that call _dispatch_require('supervisor'). That helper is
  -- shared with other screens, so only these callers are changed.
  foreach fn in array array[
    'dispatch_check_save(bigint, jsonb)', 'dispatch_sub_override(bigint, text)',
    'dispatch_sub_resolve(bigint, text, boolean, text)'
  ] loop
    def := pg_get_functiondef(fn::regprocedure);
    new := replace(def, 'perform _dispatch_require(''supervisor'');',
                        'if not dispatch_has_role(''invoicer'') then perform _dispatch_require(''supervisor''); end if;');
    if new = def then raise exception 'no role check found in %', fn; end if;
    execute new;
  end loop;

  -- The Admin page's role picker.
  def := pg_get_functiondef('admin_set_roles(text, text[])'::regprocedure);
  new := replace(def, '''manager'', ''security'', ''admin'']', '''manager'', ''security'', ''admin'', ''invoicer'']');
  if new = def then raise exception 'no allowed list found in admin_set_roles'; end if;
  execute new;
end $$;

insert into public.dispatch_role_invites (email, role) values
  ('shaniqued@dflimporters.com', 'invoicer'),
  ('tiffany@dflimporters.com', 'invoicer')
on conflict do nothing;

insert into public.dispatch_roles (user_id, role)
select u.id, i.role from public.dispatch_role_invites i
  join auth.users u on lower(u.email) = i.email
 where i.role = 'invoicer'
on conflict do nothing;
