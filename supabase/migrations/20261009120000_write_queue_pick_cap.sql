-- 1. Acumatica write queue (Joel, 2026-10-09: the liaison had to wait for one
--    load to finish writing before starting the next).
--    The pages now only ask: dispatch-acu "apply" sets write_requested_at and
--    "check_confirm" sets confirm_requested_at, then returns at once. A drain
--    run (started by that request, and every minute by cron as a safety net)
--    takes the queue oldest first, one load at a time per Acumatica target,
--    in one Acumatica session. The pages poll loads / load_shipments for
--    progress.
alter table public.loads
  add column write_requested_at   timestamptz,
  add column write_requested_by   text,
  add column confirm_requested_at timestamptz,
  add column confirm_requested_by text;

create index loads_write_queue on public.loads (env, write_requested_at) where write_requested_at is not null;
create index loads_confirm_queue on public.loads (env, confirm_requested_at) where confirm_requested_at is not null;

-- 2. A picker can't record more than the load needs (Joel, 2026-10-09).
create or replace function public.dispatch_pick_set(p_load_id bigint, p_inventory_id text, p_picked numeric, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare l loads; v_req numeric;
begin
  perform _dispatch_require('picker');
  l := _dispatch_pickable(p_load_id);
  if p_picked is null then
    delete from pick_lines where load_id = p_load_id and inventory_id = p_inventory_id;
  else
    if p_picked < 0 then raise exception 'Picked quantity can''t be negative'; end if;
    select coalesce(sum(sl.shipped_qty), 0) into v_req
      from load_shipments ls join shipment_lines sl on sl.env = l.env and sl.shipment_nbr = ls.shipment_nbr
     where ls.load_id = p_load_id and sl.inventory_id = p_inventory_id and sl.shipped_qty > 0;
    if p_picked > v_req then
      raise exception 'Only % of % needed on %; you can''t pick more than that', v_req, p_inventory_id, l.load_nbr;
    end if;
    insert into pick_lines (load_id, inventory_id, picked_qty, note, picker_name)
    values (p_load_id, p_inventory_id, p_picked, nullif(trim(p_note), ''), dispatch_actor_name())
    on conflict (load_id, inventory_id) do update
      set picked_qty = excluded.picked_qty, note = excluded.note, picked_by = auth.uid(),
          picker_name = excluded.picker_name, picked_at = now();
  end if;
end $$;

-- 3. Safety net for the queue: every minute, drain anything still waiting
--    (a request that arrived while another run was finishing, or a run that
--    hit its time budget). Does nothing, and doesn't sign in, when it's empty.
select cron.schedule('dispatch-acu-drain-1min', '* * * * *', $cron$
  select net.http_post(
    url := 'https://hzagwndglwhcepsirafi.supabase.co/functions/v1/dispatch-acu',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'dispatch_cron_token')),
    body := '{"action":"drain"}'::jsonb, timeout_milliseconds := 5000)
$cron$);
