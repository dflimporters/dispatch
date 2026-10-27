-- Admin page backend (Joel, 2026-10-27): who has access, who changed what, load lookup, sync health.
--
-- 1. Role 'admin' on dispatch_roles / dispatch_role_invites. Admin manages users and reads the audit
--    log; it grants nothing else (an admin still needs the working roles to use the other pages).
--    Seeded for active profiles.role = 'admin'.
-- 2. admin_users / admin_set_roles: list users and pending invites; grant, change, remove roles.
--    dispatch_role_invites stays locked (revoke all); only these security-definer functions write it.
--    Guards: can't take your own admin role away, and the last admin can't be removed.
--    "Remove" = no dispatch roles (and no invite). It does not touch auth.users or dflhq.com.
-- 3. audit_log: append-only (who, when, what, before/after). Written by _audit(), which clients can't
--    call. Hooks (triggers, so the existing write functions are untouched):
--      loads.ship_via change                -> load.ship_via
--      loads.closed_at set / reopened       -> load.closed / load.reopened
--      loads.sheet_stale_at cleared (print) -> load.sheet_reprint
--      shipments.ship_via change            -> shipment.ship_via  (actor null = Acumatica / sync)
--      load_events of reassign, unconfirm, pick_reopen, check_reopen, unstick, delete, pull_back, return
--      lm_returns.status change             -> return.status  (release etc.)
--    Role changes are logged by admin_set_roles. admin_audit() reads it with filters.
-- 4. admin_load_find / admin_load_detail: look a load up by number (or shipment / order number).
--    Read-only; admins and supervisors. Everything else here is admin only.
-- 5. admin_sync_health: cron jobs, data freshness, recent failed HTTP calls, write queues, items needing attention.
--
-- Rollback at the bottom.

-- ------------------------------------------------------------------
-- 1. Role
-- ------------------------------------------------------------------
alter table public.dispatch_roles drop constraint dispatch_roles_role_check;
alter table public.dispatch_roles add constraint dispatch_roles_role_check
  check (role in ('batcher', 'clerk', 'picker', 'checker', 'supervisor', 'manager', 'security', 'admin'));
alter table public.dispatch_role_invites drop constraint dispatch_role_invites_role_check;
alter table public.dispatch_role_invites add constraint dispatch_role_invites_role_check
  check (role in ('batcher', 'clerk', 'picker', 'checker', 'supervisor', 'manager', 'security', 'admin'));

insert into public.dispatch_roles (user_id, role)
select p.id, 'admin' from public.profiles p
 where p.role = 'admin' and p.active
on conflict do nothing;

create function public._admin_ok() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (select 1 from dispatch_roles where user_id = auth.uid() and role = 'admin');
$$;

create function public._admin_require() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not _admin_ok() then raise exception 'Admin only' using errcode = '42501'; end if;
end $$;

-- Load lookup is read-only and also open to supervisors (Joel, 2026-10-27). Everything that
-- changes data, and user management, stays admin only.
create function public._admin_read_require() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not (_admin_ok() or dispatch_has_role('supervisor')) then raise exception 'Admin or supervisor only' using errcode = '42501'; end if;
end $$;
revoke all on function public._admin_read_require() from public, anon, authenticated;

-- ------------------------------------------------------------------
-- 2. Audit log
-- ------------------------------------------------------------------
create table public.audit_log (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  actor_id     uuid,                 -- null = system (sync, cron, edge function)
  actor_name   text,
  action       text not null,        -- 'user.roles', 'load.ship_via', ...
  entity       text not null,        -- 'user' | 'load' | 'shipment' | 'return'
  entity_id    text,
  env          text,
  load_id      bigint,
  load_nbr     text,
  shipment_nbr text,
  before       jsonb,
  after        jsonb,
  note         text
);
create index audit_log_at       on public.audit_log (at desc);
create index audit_log_load     on public.audit_log (load_id, at desc) where load_id is not null;
create index audit_log_shipment on public.audit_log (shipment_nbr, at desc) where shipment_nbr is not null;
create index audit_log_action   on public.audit_log (action, at desc);
alter table public.audit_log enable row level security;       -- no policies: only the functions below read it
revoke all on public.audit_log from anon, authenticated;

create function public._audit_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'audit_log is append-only';
end $$;
create trigger audit_log_immutable before update or delete on public.audit_log
  for each row execute function public._audit_immutable();

create function public._audit(p_action text, p_entity text, p_entity_id text default null, p_note text default null,
                              p_before jsonb default null, p_after jsonb default null,
                              p_env text default null, p_load_id bigint default null, p_load_nbr text default null,
                              p_shipment_nbr text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into audit_log (actor_id, actor_name, action, entity, entity_id, env, load_id, load_nbr, shipment_nbr, before, after, note)
  values (auth.uid(), case when auth.uid() is null then null else dispatch_actor_name() end,
          p_action, p_entity, p_entity_id, p_env, p_load_id, p_load_nbr, p_shipment_nbr, p_before, p_after, p_note);
end $$;
revoke all on function public._audit(text, text, text, text, jsonb, jsonb, text, bigint, text, text) from public, anon, authenticated;

-- Hooks: a logging failure must never block the real write, so each trigger swallows its own errors.
create function public._audit_loads_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin
    if old.ship_via is distinct from new.ship_via then
      perform _audit('load.ship_via', 'load', new.id::text,
        coalesce(old.ship_via, '—') || ' → ' || coalesce(new.ship_via, '—'),
        jsonb_build_object('ship_via', old.ship_via, 'contractor', old.contractor),
        jsonb_build_object('ship_via', new.ship_via, 'contractor', new.contractor),
        new.env, new.id, new.load_nbr);
    end if;
    if old.closed_at is distinct from new.closed_at then
      perform _audit(case when new.closed_at is null then 'load.reopened' else 'load.closed' end, 'load', new.id::text,
        new.closed_reason, null, null, new.env, new.id, new.load_nbr);
    end if;
    if old.sheet_stale_at is not null and new.sheet_stale_at is null then
      perform _audit('load.sheet_reprint', 'load', new.id::text, 'Updated load sheet printed',
        null, null, new.env, new.id, new.load_nbr);
    end if;
  exception when others then
    raise warning 'audit loads trigger: %', sqlerrm;
  end;
  return new;
end $$;
create trigger audit_loads after update on public.loads
  for each row
  when (old.ship_via is distinct from new.ship_via or old.closed_at is distinct from new.closed_at
        or (old.sheet_stale_at is not null and new.sheet_stale_at is null))
  execute function public._audit_loads_trg();

create function public._audit_shipments_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare ls record;
begin
  begin
    select l.id, l.load_nbr into ls from load_shipments s join loads l on l.id = s.load_id
     where s.env = 'live' and s.shipment_nbr = new.shipment_nbr limit 1;
    perform _audit('shipment.ship_via', 'shipment', new.shipment_nbr,
      coalesce(old.ship_via, '—') || ' → ' || coalesce(new.ship_via, '—'),
      jsonb_build_object('ship_via', old.ship_via), jsonb_build_object('ship_via', new.ship_via),
      'live', ls.id, ls.load_nbr, new.shipment_nbr);
  exception when others then
    raise warning 'audit shipments trigger: %', sqlerrm;
  end;
  return new;
end $$;
create trigger audit_shipments after update of ship_via on public.shipments
  for each row when (old.ship_via is distinct from new.ship_via)
  execute function public._audit_shipments_trg();

create function public._audit_load_events_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin
    if new.kind in ('reassign', 'unconfirm', 'pick_reopen', 'check_reopen', 'unstick', 'delete', 'pull_back', 'return') then
      perform _audit('load.' || new.kind, 'load', new.load_id::text, new.note,
        null, new.detail, new.env, new.load_id, new.load_nbr);
    end if;
  exception when others then
    raise warning 'audit load_events trigger: %', sqlerrm;
  end;
  return new;
end $$;
create trigger audit_load_events after insert on public.load_events
  for each row execute function public._audit_load_events_trg();

create function public._audit_returns_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin
    perform _audit('return.status', 'return', new.id::text, old.status || ' → ' || new.status,
      jsonb_build_object('status', old.status), jsonb_build_object('status', new.status),
      null, new.load_id, (select load_nbr from loads where id = new.load_id));
  exception when others then
    raise warning 'audit returns trigger: %', sqlerrm;
  end;
  return new;
end $$;
create trigger audit_returns after update of status on public.lm_returns
  for each row when (old.status is distinct from new.status)
  execute function public._audit_returns_trg();

revoke all on function public._audit_loads_trg(), public._audit_shipments_trg(), public._audit_load_events_trg(),
  public._audit_returns_trg() from public, anon, authenticated;
revoke all on function public._admin_ok(), public._admin_require() from public, anon;
grant execute on function public._admin_ok() to authenticated;   -- the page reads it through dispatch_me roles, harmless

-- ------------------------------------------------------------------
-- 3. Users and invites
-- ------------------------------------------------------------------
create function public.admin_users() returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
begin
  perform _admin_require();
  return jsonb_build_object(
    'users', coalesce((
      select jsonb_agg(jsonb_build_object(
               'user_id', u.id, 'email', u.email, 'name', p.full_name,
               'roles', r.roles, 'last_sign_in_at', u.last_sign_in_at, 'created_at', u.created_at,
               'portal_active', p.active)
             order by lower(coalesce(p.full_name, u.email)))
        from (select user_id, jsonb_agg(role order by role) roles from dispatch_roles group by user_id) r
        join auth.users u on u.id = r.user_id
        left join profiles p on p.id = u.id), '[]'::jsonb),
    'invites', coalesce((
      select jsonb_agg(jsonb_build_object('email', i.email, 'roles', i.roles, 'created_at', i.created_at) order by i.email)
        from (select email, jsonb_agg(role order by role) roles, min(created_at) created_at
                from dispatch_role_invites group by email) i
       where not exists (select 1 from auth.users u where lower(u.email) = i.email)), '[]'::jsonb));
end $$;

-- Replaces the person's dispatch roles with exactly p_roles. Empty = remove access.
-- Existing account: dispatch_roles. No account yet: dispatch_role_invites (applied at first sign-in).
create function public.admin_set_roles(p_email text, p_roles text[]) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  em     text := lower(btrim(coalesce(p_email, '')));
  want   text[];
  uid    uuid;
  prev   text[];
  action text;
  allowed text[] := array['batcher', 'clerk', 'picker', 'checker', 'supervisor', 'manager', 'security', 'admin'];
begin
  perform _admin_require();
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address'; end if;
  select coalesce(array_agg(distinct x order by x), '{}') into want from unnest(coalesce(p_roles, '{}')) x;
  if exists (select 1 from unnest(want) x where x <> all (allowed)) then raise exception 'Unknown role'; end if;
  perform pg_advisory_xact_lock(hashtext('admin_set_roles'));

  select id into uid from auth.users where lower(email) = em limit 1;
  if uid is not null then
    select coalesce(array_agg(role order by role), '{}') into prev from dispatch_roles where user_id = uid;
  else
    select coalesce(array_agg(role order by role), '{}') into prev from dispatch_role_invites where email = em;
  end if;

  -- Never lock everyone out of this page.
  if 'admin' = any (prev) and not 'admin' = any (want) then
    if uid = auth.uid() then raise exception 'You can''t remove your own admin role; ask another admin'; end if;
    if not exists (select 1 from dispatch_roles where role = 'admin' and user_id is distinct from uid) then
      raise exception 'That would leave no admin';
    end if;
  end if;

  if uid is not null then
    delete from dispatch_roles where user_id = uid and role <> all (want);
    insert into dispatch_roles (user_id, role) select uid, x from unnest(want) x on conflict do nothing;
    delete from dispatch_role_invites where email = em;
  else
    delete from dispatch_role_invites where email = em and role <> all (want);
    insert into dispatch_role_invites (email, role) select em, x from unnest(want) x on conflict do nothing;
  end if;

  if prev = want then
    return jsonb_build_object('email', em, 'roles', to_jsonb(want), 'pending', uid is null, 'changed', false);
  end if;
  action := case when cardinality(want) = 0 then 'user.removed'
                 when cardinality(prev) = 0 then 'user.invited' else 'user.roles' end;
  perform _audit(action, 'user', coalesce(uid::text, em), em || ': ' || coalesce(nullif(array_to_string(prev, ', '), ''), 'none')
                   || ' → ' || coalesce(nullif(array_to_string(want, ', '), ''), 'none') || case when uid is null then ' (not signed in yet)' else '' end,
                 jsonb_build_object('email', em, 'roles', to_jsonb(prev)), jsonb_build_object('email', em, 'roles', to_jsonb(want)));
  return jsonb_build_object('email', em, 'roles', to_jsonb(want), 'pending', uid is null, 'changed', true);
end $$;

-- ------------------------------------------------------------------
-- 4. Audit viewer
-- ------------------------------------------------------------------
-- p_action: exact action or a prefix ending in '.' (e.g. 'load.'); p_q: matches load / shipment / entity / actor / note.
create function public.admin_audit(p_action text default null, p_q text default null,
                                   p_from timestamptz default null, p_to timestamptz default null,
                                   p_limit int default 200, p_before bigint default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare q text := nullif(btrim(coalesce(p_q, '')), '');
begin
  perform _admin_require();
  return coalesce((
    select jsonb_agg(to_jsonb(a) order by a.id desc) from (
      select id, at, actor_name, action, entity, entity_id, env, load_nbr, shipment_nbr, before, after, note
        from audit_log
       where (p_action is null or action = p_action or (right(p_action, 1) = '.' and action like p_action || '%'))
         and (p_from is null or at >= p_from) and (p_to is null or at < p_to)
         and (p_before is null or id < p_before)
         and (q is null or load_nbr ilike '%' || q || '%' or shipment_nbr ilike '%' || q || '%'
              or entity_id ilike '%' || q || '%' or actor_name ilike '%' || q || '%' or note ilike '%' || q || '%')
       order by id desc limit least(greatest(coalesce(p_limit, 200), 1), 500)) a), '[]'::jsonb);
end $$;

-- ------------------------------------------------------------------
-- 5. Load lookup
-- ------------------------------------------------------------------
-- By load number (partial ok), or the shipment / order number of something on the load.
create function public.admin_load_find(p_q text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare q text := nullif(btrim(coalesce(p_q, '')), '');
begin
  perform _admin_read_require();
  if q is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.load_date desc, x.id desc) from (
      select l.id, l.env, l.load_nbr, l.load_date, l.status, l.check_status, l.ship_via, l.closed_at,
             (select count(*) from load_shipments ls where ls.load_id = l.id)::int as shipments
        from loads l
       where l.load_nbr ilike '%' || q || '%'
          or exists (select 1 from load_shipments ls where ls.load_id = l.id and ls.shipment_nbr ilike q || '%')
          or exists (select 1 from load_shipments ls join _dispatch_shipments(l.env) s on s.shipment_nbr = ls.shipment_nbr
                      where ls.load_id = l.id and s.order_nbr ilike q || '%')
       order by l.load_date desc, l.id desc limit 25) x), '[]'::jsonb);
end $$;

create function public.admin_load_detail(p_load_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l loads; out jsonb;
begin
  perform _admin_read_require();
  select * into l from loads where id = p_load_id;
  if not found then raise exception 'Load not found'; end if;

  select jsonb_build_object(
    'load', to_jsonb(l),
    'claim', (select jsonb_build_object('claim_code', m.claim_code, 'status', m.status, 'claimed_name', m.claimed_name,
                                        'claimed_at', m.claimed_at, 'delivering_at', m.delivering_at,
                                        'completed_at', m.completed_at, 'closed_at', m.closed_at, 'aborted_at', m.aborted_at,
                                        'abort_reason', m.abort_reason)
                from lm_loads m where m.load_id = l.id),
    'pick', (select jsonb_build_object(
               'items', count(*), 'picked_items', count(*) filter (where x.picked_qty is not null),
               'required', coalesce(sum(x.required), 0), 'picked', coalesce(sum(x.picked_qty), 0),
               'short_items', count(*) filter (where x.picked_qty is not null and x.picked_qty < x.required),
               'areas_done', (select coalesce(jsonb_agg(jsonb_build_object('area', a.area, 'by', a.done_name, 'at', a.done_at) order by a.area), '[]'::jsonb)
                                from pick_area_status a where a.load_id = l.id),
               'areas_staged', (select coalesce(jsonb_agg(jsonb_build_object('area', a.area, 'by', a.staged_name, 'at', a.staged_at) order by a.area), '[]'::jsonb)
                                  from stage_area_status a where a.load_id = l.id),
               'last_pick_at', max(x.picked_at))
               from dispatch_pick_list(l.id) x),
    'check', jsonb_build_object(
               'status', l.check_status, 'done_by', l.checker_done_name, 'done_at', l.checker_done_at,
               'lines_saved', (select count(*) from check_lines c where c.load_id = l.id),
               'lines_lowered', (select count(*) from check_lines c where c.load_id = l.id and c.final_qty < c.shipped_qty)),
    'shipments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'shipment_nbr', ls.shipment_nbr, 'order_nbr', s.order_nbr, 'customer_id', s.customer_id,
               'customer_name', s.customer_name, 'zone', s.shipping_zone,
               'ship_via', s.ship_via, 'ship_via_before', ls.ship_via_before, 'status', s.status, 'shipment_date', s.shipment_date,
               'value', s.shipment_value, 'in_data', s.shipment_nbr is not null,
               'write_result', ls.result, 'write_detail', ls.result_detail, 'write_at', ls.result_at,
               'check_result', ls.check_result, 'check_detail', ls.check_detail, 'check_at', ls.check_at,
               'invoicing', (select jsonb_build_object('state', si.state, 'detail', si.detail, 'at', si.updated_at)
                               from shipment_invoicing si where si.env = ls.env and si.shipment_nbr = ls.shipment_nbr),
               'invoices', case when ls.env = 'live' then coalesce((
                    select jsonb_agg(jsonb_build_object('nbr', i.reference_number, 'status', i.status, 'ship_via', i.ship_via,
                                                        'amount', i.invoice_amount, 'date', i.invoice_date,
                                                        'deliver_via', d.deliver_via, 'deliver_state', d.acu_state, 'deliver_detail', d.acu_detail)
                                      order by i.reference_number)
                      from invoices i left join invoice_deliver_via d on d.invoice_nbr = i.reference_number
                     where s.order_nbr is not null and i.order_number = s.order_nbr), '[]'::jsonb) else '[]'::jsonb end)
             order by s.customer_name, ls.shipment_nbr)
        from load_shipments ls
        left join lateral (select * from _dispatch_shipments(ls.env) x where x.shipment_nbr = ls.shipment_nbr) s on true
       where ls.load_id = l.id), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at desc) from (
                select kind, outcome, ship_via, contractor, note, actor_name, created_at
                  from load_events where load_id = l.id order by created_at desc limit 100) e), '[]'::jsonb),
    'audit', coalesce((select jsonb_agg(to_jsonb(a) order by a.id desc) from (
                select id, at, actor_name, action, shipment_nbr, before, after, note from audit_log
                 where load_id = l.id
                    or shipment_nbr in (select shipment_nbr from load_shipments where load_id = l.id)
                 order by id desc limit 200) a), '[]'::jsonb))
  into out;
  return out;
end $$;

-- ------------------------------------------------------------------
-- 6. Sync health
-- ------------------------------------------------------------------
create function public.admin_sync_health() returns jsonb
language plpgsql stable security definer set search_path = public, cron, net as $$
declare jobs jsonb; fresh jsonb; http jsonb := '[]'::jsonb; http_n jsonb := '{}'::jsonb; queue jsonb; attn jsonb;
begin
  perform _admin_require();

  -- "succeeded" only means pg_cron sent the request; the HTTP result is in `http` below.
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', j.jobname, 'schedule', j.schedule, 'active', j.active,
           'last_status', d.status, 'last_start', d.start_time, 'last_end', d.end_time, 'last_message', left(d.return_message, 300))
         order by j.jobname), '[]'::jsonb)
    into jobs
    from cron.job j
    left join lateral (select * from cron.job_run_details d where d.jobid = j.jobid order by d.start_time desc limit 1) d on true
   where j.jobname ~* '^(sync|dispatch)';

  select jsonb_build_object(
    'shipments',          (select max(synced_at) from shipments),
    'shipment_lines',     (select max(synced_at) from shipment_lines where env = 'live'),
    'invoices',           (select max(synced_at) from invoices),
    'so_ordered_items',   (select max(synced_at) from so_ordered_items),
    'ship_via_codes',     (select max(synced_at) from ship_via_codes),
    'customers',          (select max(synced_at) from customers))
    into fresh;

  begin
    select coalesce(jsonb_agg(jsonb_build_object('at', r.created, 'status', r.status_code, 'error', r.error_msg,
                                                 'timed_out', r.timed_out, 'body', left(r.content, 300)) order by r.created desc), '[]'::jsonb)
      into http
      from (select * from net._http_response
             where created > now() - interval '6 hours' and (status_code >= 400 or error_msg is not null or timed_out)
             order by created desc limit 20) r;
    select jsonb_build_object('ok', count(*) filter (where status_code between 200 and 299),
                              'failed', count(*) filter (where status_code >= 400 or error_msg is not null or timed_out))
      into http_n from net._http_response where created > now() - interval '1 hour';
  exception when others then
    http := '[]'::jsonb; http_n := jsonb_build_object('error', sqlerrm);
  end;

  select jsonb_build_object(
    'writes_waiting',   (select count(*) from loads where write_requested_at is not null and status in ('confirmed', 'partial')),
    'confirms_waiting', (select count(*) from loads where confirm_requested_at is not null and check_status in ('checking', 'partial', 'confirming')),
    'invoices_queued',  (select count(*) from shipment_invoicing where state in ('queued', 'running')),
    'leases',           (select coalesce(jsonb_agg(jsonb_build_object('target', target, 'job', job, 'taken_at', taken_at, 'expires_at', expires_at)), '[]'::jsonb)
                           from acu_leases where expires_at > now()))
    into queue;

  -- Items needing a human (stretch: read-only for now).
  select coalesce(jsonb_agg(x order by x->>'at'), '[]'::jsonb) into attn from (
    select jsonb_build_object('kind', 'write_waiting', 'load_id', id, 'load_nbr', load_nbr, 'at', write_requested_at,
                              'note', 'Trucker write waiting in the queue for over 15 minutes') x
      from loads where write_requested_at < now() - interval '15 minutes' and status in ('confirmed', 'partial')
    union all
    select jsonb_build_object('kind', 'confirm_waiting', 'load_id', id, 'load_nbr', load_nbr, 'at', confirm_requested_at,
                              'note', 'Confirm in Acumatica waiting for over 15 minutes')
      from loads where confirm_requested_at < now() - interval '15 minutes' and check_status in ('checking', 'partial', 'confirming')
    union all
    select jsonb_build_object('kind', 'write_' || ls.result, 'load_id', l.id, 'load_nbr', l.load_nbr, 'at', ls.result_at,
                              'note', ls.shipment_nbr || ': ' || coalesce(ls.result_detail, ls.result))
      from load_shipments ls join loads l on l.id = ls.load_id
     where ls.env = 'live' and ls.result in ('failed', 'refused') and l.closed_at is null and l.check_status is distinct from 'confirmed'
    union all
    select jsonb_build_object('kind', 'confirm_' || ls.check_result, 'load_id', l.id, 'load_nbr', l.load_nbr, 'at', ls.check_at,
                              'note', ls.shipment_nbr || ': ' || coalesce(ls.check_detail, ls.check_result))
      from load_shipments ls join loads l on l.id = ls.load_id
     where ls.env = 'live' and ls.check_result in ('failed', 'refused') and l.closed_at is null and l.check_status is distinct from 'confirmed'
    union all
    select jsonb_build_object('kind', 'invoice_' || state, 'shipment_nbr', shipment_nbr, 'at', updated_at,
                              'note', shipment_nbr || ': ' || coalesce(detail, state))
      from shipment_invoicing where env = 'live' and (state in ('failed', 'refused') or (state in ('queued', 'running') and updated_at < now() - interval '30 minutes'))
    union all
    select jsonb_build_object('kind', 'deliver_via_failed', 'shipment_nbr', shipment_nbr, 'load_nbr', load_nbr, 'at', acu_at,
                              'note', invoice_nbr || ': ' || coalesce(acu_detail, 'failed'))
      from invoice_deliver_via where acu_state = 'failed'
  ) t;

  return jsonb_build_object('now', now(), 'jobs', jobs, 'fresh', fresh, 'http_failures', http, 'http_last_hour', http_n,
                            'queue', queue, 'attention', attn);
end $$;

-- Run-now for the functions that only accept the cron token (the browser can't send it): calls
-- through pg_net with the Vault token, same as cron. Whitelisted.
create function public.admin_run_sync(p_fn text) returns jsonb
language plpgsql security definer set search_path = public, net, vault as $$
declare tok text; body jsonb; rid bigint;
begin
  perform _admin_require();
  if p_fn not in ('sync-so-ordered-items', 'dispatch-acu:sync_live_lines') then raise exception 'Not allowed'; end if;
  select decrypted_secret into tok from vault.decrypted_secrets where name = 'dispatch_cron_token';
  if tok is null then raise exception 'dispatch_cron_token is missing'; end if;
  body := case when p_fn = 'dispatch-acu:sync_live_lines' then '{"action":"sync_live_lines"}'::jsonb else '{}'::jsonb end;
  select net.http_post(
           url := 'https://hzagwndglwhcepsirafi.supabase.co/functions/v1/' || split_part(p_fn, ':', 1),
           headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || tok),
           body := body, timeout_milliseconds := 120000) into rid;
  perform _audit('sync.run_now', 'sync', p_fn, 'Run now: ' || p_fn);
  return jsonb_build_object('queued', true, 'request_id', rid);
end $$;

revoke all on function public.admin_users(), public.admin_sync_health(), public.admin_load_find(text),
  public.admin_load_detail(bigint), public.admin_set_roles(text, text[]),
  public.admin_audit(text, text, timestamptz, timestamptz, int, bigint), public.admin_run_sync(text) from public, anon;
grant execute on function public.admin_users(), public.admin_sync_health(), public.admin_load_find(text),
  public.admin_load_detail(bigint), public.admin_set_roles(text, text[]),
  public.admin_audit(text, text, timestamptz, timestamptz, int, bigint), public.admin_run_sync(text) to authenticated;

-- Rollback (by hand):
-- drop trigger audit_loads on public.loads; drop trigger audit_shipments on public.shipments;
-- drop trigger audit_load_events on public.load_events; drop trigger audit_returns on public.lm_returns;
-- drop function public._audit_loads_trg(), public._audit_shipments_trg(), public._audit_load_events_trg(), public._audit_returns_trg();
-- drop function public.admin_run_sync(text), public.admin_sync_health(), public.admin_load_detail(bigint), public.admin_load_find(text),
--   public.admin_audit(text, text, timestamptz, timestamptz, int, bigint), public.admin_set_roles(text, text[]), public.admin_users();
-- drop table public.audit_log; drop function public._audit(text, text, text, text, jsonb, jsonb, text, bigint, text, text), public._audit_immutable();
-- drop function public._admin_read_require(), public._admin_require(), public._admin_ok();
-- delete from public.dispatch_roles where role = 'admin'; delete from public.dispatch_role_invites where role = 'admin';
-- then restore both role check constraints without 'admin' (see 20261026120000_driver_security_contacts.sql).
