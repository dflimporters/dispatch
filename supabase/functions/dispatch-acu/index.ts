// Supabase Edge Function: dispatch-acu
// The dispatch pages' only route into Acumatica.
//
// POST JSON { action, ... } with the signed-in user's access token as
// Authorization: Bearer <token>. verify_jwt is off because the token is
// checked here (auth.getUser) along with the caller's dispatch role.
//
//   status                 -> test target, whether live writeback is on, UDF name. Any dispatch role.
//   sync_test              -> mirror the test target's open/confirmed shipments into shipments_test. Any dispatch role.
//   sync_live_lines        -> read-only: production's Open/On Hold shipments' line items into
//                             shipment_lines (env 'live') + shipments.shipment_value. Run by
//                             cron with the Vault token (dispatch_cron_ok), or by any dispatch role.
//   check_confirm { load_id } -> checker only. Queues the load; the drain then, for each
//                             shipment on it: lowers or deletes the lines the checker reduced
//                             (check_lines), sets Control Qty to the new shipped qty, Confirm
//                             Shipment, reads it back. Live loads also need
//                             DISPATCH_LIVE_CHECKER = 'on' (switched on after a pilot).
//   apply { load_id }      -> clerk only. Queues the load; the drain then, for each shipment on
//                             it: sets ShipVia + load number UDF, takes it off hold, reads it back.
//                             It does NOT confirm: the shipment stays Open for picking, and the
//                             checker's step confirms it once the pick has been checked.
//   invoice_request { env, shipments[] } -> supervisor only. Queues Prepare Invoice for Confirmed
//                             shipments (shipment_invoicing); the drain runs it, one shipment at a
//                             time, and records the result. Releasing the invoice stays with
//                             Accounts. Live also needs DISPATCH_LIVE_INVOICE = 'on'.
//   drain                  -> cron (Vault token) every minute: work through anything queued.
//
// Queue: apply and check_confirm only mark the load (write_requested_at /
// confirm_requested_at) and answer at once, so the pages never wait on
// Acumatica. The work runs in the background (EdgeRuntime.waitUntil): one
// drain per target holds the lease and takes queued loads oldest first in one
// Acumatica session, writing each shipment's result as it goes; the pages poll
// that for progress. A request that finds another drain running leaves it to
// that one, which re-reads the queue after letting go of the lease.
//
// Guards per shipment (anything else is "refused" and left untouched):
//   - status is On Hold or Open
//   - current ShipVia is what it was when the clerk confirmed (ship_via_before),
//     or already the target (a retry)
// A shipment already Confirmed with the target ShipVia counts as applied.
//
// Targets (see TARGETS): env 'test' loads go to DISPATCH_TEST_TARGET, either
// 'test' (2024R2 TEST tenant on production; refuses unless ACU_SHIPVIA_TENANT
// is exactly TEST) or 'sandbox26' (2026R1 sandbox). env 'live' loads are refused
// until DISPATCH_LIVE_WRITEBACK = 'on' and the ACU_LIVE_* secrets are set.
//
// One run at a time per target (acu_lease_take), and calls within a run are
// spaced by the target's gapMs, to stay inside Acumatica's API limits.
// Always signs out of Acumatica so no API session is left open.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

type Target = {
  key: string; label: string; base: string; version: string;
  username: string; password: string; tenant: string;
  gapMs: number;           // minimum time between API calls in one run
  check(): string | null;  // why this target can't be used, or null
  readCheck?(): string | null;  // for read-only jobs, when that differs from check()
};
// Production: 6 concurrent / 150 per min. One run at a time at <=60/min
// leaves room for the 5-minute sync and other integrations.
// Sandbox: 1 concurrent / 50 per min.
const TARGETS: Record<string, Target> = {
  test: {
    key: 'test', label: 'Acumatica TEST (2024R2)',
    base: 'https://dflimporters.acumatica.com', version: '24.200.001',
    username: Deno.env.get('ACU_SHIPVIA_USERNAME') ?? '', password: Deno.env.get('ACU_SHIPVIA_PASSWORD') ?? '',
    tenant: Deno.env.get('ACU_SHIPVIA_TENANT') ?? '', gapMs: 1000,
    check() { return this.tenant === 'TEST' ? null : `refusing: ACU_SHIPVIA_TENANT is '${this.tenant}', not 'TEST'`; },
  },
  sandbox26: {
    key: 'sandbox26', label: 'Acumatica 2026R1 sandbox',
    base: 'https://dflimporters-sandbox-26-1.acumatica.com', version: '24.200.001',
    username: Deno.env.get('ACU_SANDBOX_USERNAME') ?? Deno.env.get('ACU_SHIPVIA_USERNAME') ?? '',
    password: Deno.env.get('ACU_SANDBOX_PASSWORD') ?? Deno.env.get('ACU_SHIPVIA_PASSWORD') ?? '',
    tenant: Deno.env.get('ACU_SANDBOX_TENANT') ?? 'DFL Importers', gapMs: 1300,
    check() { return this.base.includes('sandbox') ? null : 'refusing: sandbox target does not point at a sandbox'; },
  },
  live: {
    key: 'live', label: 'Acumatica (live)',
    base: 'https://dflimporters.acumatica.com', version: '24.200.001',
    // Same API login as TEST (Joel set the user up identically in production);
    // ACU_LIVE_USERNAME / _PASSWORD override it if a separate user is made later.
    username: Deno.env.get('ACU_LIVE_USERNAME') ?? Deno.env.get('ACU_SHIPVIA_USERNAME') ?? '',
    password: Deno.env.get('ACU_LIVE_PASSWORD') ?? Deno.env.get('ACU_SHIPVIA_PASSWORD') ?? '',
    tenant: Deno.env.get('ACU_LIVE_TENANT') ?? '', gapMs: 1000,
    check() {
      return Deno.env.get('DISPATCH_LIVE_WRITEBACK') === 'on' && this.username && this.tenant
        ? null : 'Live writeback isn\'t switched on yet. Test loads only for now.';
    },
    // Reading production (line items for the pages) only needs the login.
    readCheck() {
      return this.username && this.password && this.tenant ? null : 'Live Acumatica login (ACU_LIVE_*) isn\'t set up yet';
    },
  },
};
const TEST_TARGET = Deno.env.get('DISPATCH_TEST_TARGET') ?? 'test';
const LIVE_ON = TARGETS.live.check() === null;
const LIVE_CHECKER_ON = Deno.env.get('DISPATCH_LIVE_CHECKER') === 'on';
const LIVE_INVOICE_ON = Deno.env.get('DISPATCH_LIVE_INVOICE') === 'on';

function targetFor(env: string): Target {
  const t = env === 'live' ? TARGETS.live : TARGETS[TEST_TARGET];
  if (!t || (env !== 'live' && t.key === 'live')) throw new Error(`refusing: DISPATCH_TEST_TARGET '${TEST_TARGET}' isn't a test target`);
  const why = t.check();
  if (why) throw new Error(why);
  return t;
}
function readTargetFor(env: string): Target {
  if (env !== 'live') return targetFor(env);
  const why = TARGETS.live.readCheck!();
  if (why) throw new Error(why);
  return TARGETS.live;
}

// User-Defined Field on the Shipments screen holding the load number.
// Acumatica exposes it as custom field Document.Attribute<ID>.
const UDF_ID  = Deno.env.get('LOAD_UDF_ATTRIBUTE') ?? 'LOADNBR';
const UDF_KEY = `Attribute${UDF_ID}`;

const EDITABLE = ['On Hold', 'Open'];
const FIELDS   = 'ShipmentNbr,Status,ShipVia,Hold,ShippedQty,ControlQty,LastModifiedDateTime';
const admin = createClient(SUPABASE_URL, SERVICE_KEY);

// Any origin: access is decided by the bearer token and dispatch role, and no
// cookies are involved, so the page's origin adds nothing to check.
function cors(_req: Request): Record<string, string> {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };
}

// Acumatica wraps fields as { value } and pads some keys with spaces.
function v(field: any): any {
  const x = field?.value;
  return typeof x === 'string' ? (x.trim() || null) : (x ?? null);
}
function acuError(data: any): string {
  if (!data) return 'no detail';
  if (typeof data === 'string') return data.slice(0, 300);
  return String(data.exceptionMessage ?? data.message ?? JSON.stringify(data)).slice(0, 300);
}

// ------------------------------------------------------------------
// Acumatica REST session
// ------------------------------------------------------------------
const LEASE_WAIT_MS = 60_000;

class Acu {
  cookie = '';
  private last = 0;
  private holder = crypto.randomUUID();
  private leased = false;
  constructor(private t: Target, private job: string) {}

  private get entity() { return `${this.t.base}/entity/Default/${this.t.version}`; }

  // Space calls out so one run stays under the target's per-minute limit.
  private async pace() {
    const wait = this.last + this.t.gapMs - Date.now();
    if (wait > 0) await new Promise(r => setTimeout(r, wait));
    this.last = Date.now();
  }

  // Take (or renew) the target's lease. Waits up to a minute for another run.
  async lease() {
    const until = Date.now() + LEASE_WAIT_MS;
    for (;;) {
      const { data, error } = await admin.rpc('acu_lease_take', { p_target: this.t.key, p_holder: this.holder, p_job: this.job });
      if (error) throw new Error(`lease: ${error.message}`);
      if (data) { this.leased = true; return; }
      if (this.leased) throw new Error('Lost the Acumatica lease to another run (this one went quiet for too long)');
      if (Date.now() > until) throw new Error('Acumatica is busy with another job. Try again in a minute.');
      await new Promise(r => setTimeout(r, 2000));
    }
  }

  // One try, no waiting: true if this run now holds the target.
  async tryLease() {
    const { data, error } = await admin.rpc('acu_lease_take', { p_target: this.t.key, p_holder: this.holder, p_job: this.job });
    if (error) throw new Error(`lease: ${error.message}`);
    if (data) this.leased = true;
    return !!data;
  }

  async login() {
    await this.lease();
    await this.pace();
    const res = await fetch(`${this.t.base}/entity/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ name: this.t.username, password: this.t.password, tenant: this.t.tenant }),
    });
    if (!res.ok) throw new Error(`Acumatica sign-in failed: ${res.status} ${(await res.text()).slice(0, 300)}`);
    this.cookie = res.headers.getSetCookie().map(c => c.split(';')[0]).join('; ');
    await res.body?.cancel();
  }

  async logout() {
    try {
      if (this.cookie) {
        await this.pace();
        const res = await fetch(`${this.t.base}/entity/auth/logout`, { method: 'POST', headers: { Cookie: this.cookie } });
        await res.body?.cancel();
      }
    } catch (e) { console.error('logout failed', e); }
    if (this.leased) await admin.rpc('acu_lease_drop', { p_target: this.t.key, p_holder: this.holder });
  }

  async call(method: string, url: string, body?: unknown) {
    await this.pace();
    const res = await fetch(url.startsWith('http') ? url : `${this.entity}${url}`, {
      method,
      headers: { Cookie: this.cookie, Accept: 'application/json', 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let data: any = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = text.slice(0, 2000); }
    return { status: res.status, ok: res.ok, data, location: res.headers.get('Location') };
  }

  async getShipment(nbr: string, withUdf: boolean) {
    const q = `$select=${FIELDS}` + (withUdf ? `&$custom=Document.${UDF_KEY}` : '');
    const r = await this.call('GET', `/Shipment/${encodeURIComponent(nbr)}?${q}`);
    if (!r.ok) throw Object.assign(new Error(`couldn't read ${nbr}: ${r.status} ${acuError(r.data)}`), { status: r.status });
    return {
      id: r.data?.id as string,
      status: v(r.data?.Status), ship_via: v(r.data?.ShipVia), hold: v(r.data?.Hold),
      shipped_qty: v(r.data?.ShippedQty), control_qty: v(r.data?.ControlQty),
      udf: withUdf ? v(r.data?.custom?.Document?.[UDF_KEY]) : undefined,
    };
  }

  // Contract-based actions answer 202 + Location while running, 204 when done.
  // Used by check_confirm (ConfirmShipment) and invoicing (PrepareInvoice), not by apply.
  async shipmentAction(action: string, id: string) {
    const r = await this.call('POST', `/Shipment/${action}`, { entity: { id } });
    if (r.status === 204 || r.status === 200) return;
    if (r.status !== 202 || !r.location) throw new Error(`${action} refused: ${r.status} ${acuError(r.data)}`);
    const loc = r.location.startsWith('http') ? r.location : `${this.t.base}${r.location}`;
    for (let i = 0; i < 60; i++) {
      await new Promise(res => setTimeout(res, 1000));
      const p = await this.call('GET', loc);
      if (p.status === 204 || p.status === 200) return;
      if (p.status !== 202) throw new Error(`${action} failed: ${p.status} ${acuError(p.data)}`);
    }
    throw new Error(`${action} still running after 60s`);
  }
  confirmShipment(id: string) { return this.shipmentAction('ConfirmShipment', id); }
}

// ------------------------------------------------------------------
// apply: write one load (claimed by the drain, in its signed-in session)
// ------------------------------------------------------------------
async function applyLoad(load: any, acu: Acu) {
  const loadId = load.id as number;
  const actorName = load.write_requested_by ?? 'unknown';
  const results: any[] = [];
  let fatal: string | null = null;
  let udfOk = true;
  try {
    const { data: rows, error } = await admin.from('load_shipments')
      .select('*').eq('load_id', loadId).or('result.is.null,result.neq.applied').order('shipment_nbr');
    if (error) throw error;

    const target = load.ship_via as string;
    const mirror = load.env === 'test' ? 'shipments_test' : 'shipments';

    for (const row of rows ?? []) {
      const nbr = row.shipment_nbr as string;
      let result: 'applied' | 'refused' | 'failed' = 'failed';
      let detail = '';
      let after: any = null;
      try {
        await acu.lease();   // renew, so a long load keeps its turn
        // Try the UDF read once; if the field doesn't exist yet, carry on without it.
        let before;
        if (udfOk) {
          try { before = await acu.getShipment(nbr, true); }
          catch (e: any) { if (e.status === 404) throw e; udfOk = false; }
        }
        if (!before) before = await acu.getShipment(nbr, false);

        if (before.status === 'Confirmed' && before.ship_via === target) {
          result = 'applied'; detail = 'Already confirmed with this Ship Via'; after = before;
        } else if (!EDITABLE.includes(before.status)) {
          result = 'refused'; detail = `Status is ${before.status} in Acumatica`;
        } else if (before.ship_via !== (row.ship_via_before ?? null) && before.ship_via !== target) {
          result = 'refused'; detail = `Ship Via changed in Acumatica to ${before.ship_via ?? 'empty'} since the load was confirmed`;
        } else {
          // Ship Via + load number only. No Control Qty and no Confirm: the
          // shipment stays Open until the checker confirms it after picking.
          const body: any = { id: before.id, ShipVia: { value: target }, Hold: { value: false } };
          if (udfOk) body.custom = { Document: { [UDF_KEY]: { type: 'CustomStringField', value: load.load_nbr } } };
          const put = await acu.call('PUT', `/Shipment?$select=${FIELDS}`, body);
          if (!put.ok) throw new Error(`update refused: ${put.status} ${acuError(put.data)}`);
          after = await acu.getShipment(nbr, udfOk);
          if (after.ship_via !== target) throw new Error(`Ship Via didn't stick (reads ${after.ship_via ?? 'empty'})`);
          if (after.status !== 'Open') throw new Error(`Ship Via set, but the shipment is ${after.status}, not Open`);
          result = 'applied';
          detail = !udfOk ? `Load number not written: UDF ${UDF_ID} not found on Shipments`
                 : after.udf !== load.load_nbr ? `Load number reads ${after.udf ?? 'empty'}, expected ${load.load_nbr}` : '';
        }
      } catch (e: any) {
        result = 'failed'; detail = String(e?.message ?? e).slice(0, 400);
      }
      results.push({ shipment_nbr: nbr, result, detail });
      await admin.from('load_shipments')
        .update({ result, result_detail: detail || null, result_at: new Date().toISOString() })
        .eq('env', load.env).eq('shipment_nbr', nbr);
      // Show it on the board now rather than at the next sync.
      if (after) await admin.from(mirror).update({ ship_via: after.ship_via, status: after.status }).eq('shipment_nbr', nbr);
      await admin.from('loads').update({ status: 'writing' }).eq('id', loadId); // heartbeat for "unstick"
    }
  } catch (e: any) {
    fatal = String(e?.message ?? e);
    console.error('dispatch-acu apply', loadId, e);
  } finally {
    const { data: all } = await admin.from('load_shipments').select('result').eq('load_id', loadId);
    const done = !!all?.length && all.every(r => r.result === 'applied');
    const nothingWritten = !all?.some(r => r.result);
    const status = done ? 'done' : (nothingWritten && fatal) ? 'confirmed' : 'partial';
    await admin.from('loads').update({ status, applied_at: done ? new Date().toISOString() : null }).eq('id', loadId);
    const count = (k: string) => results.filter(r => r.result === k).length;
    await admin.from('load_events').insert({
      load_id: loadId, env: load.env, load_nbr: load.load_nbr, kind: 'writeback', ship_via: load.ship_via,
      outcome: status, actor_name: actorName,
      note: fatal ?? `${count('applied')} applied, ${count('refused')} refused, ${count('failed')} failed`,
      detail: { results, udf: udfOk },
    });
  }
  return { ok: !fatal, error: fatal, results, udf: udfOk };
}

// ------------------------------------------------------------------
// check_confirm: the checker's quantities -> Acumatica, then Confirm
// ------------------------------------------------------------------
// Per shipment (anything unexpected is "refused" and left untouched):
//   - Confirmed already -> applied. Not Open/On Hold, or no Ship Via (the
//     Nextec ConfirmShipment override requires one) -> refused.
//   - Each line's qty must still be what the checker saw (check_lines.shipped_qty),
//     else refused: re-check it.
//   - Lines lowered to 0 are deleted (the order line stays open for a later
//     shipment); other lowered lines get the new Shipped Qty. A shipment with
//     nothing left is refused: cancel it in Acumatica.
//   - Control Qty = the new shipped total (Acumatica requires it), then Confirm.
async function checkConfirm(load: any, acu: Acu) {
  const loadId = load.id as number;
  const actorName = load.confirm_requested_by ?? 'unknown';
  const results: any[] = [];
  let fatal: string | null = null;
  try {
    if (load.env === 'live' && !LIVE_CHECKER_ON)
      throw new Error('The checker can\'t confirm live shipments yet (switched on after the pilot load).');

    const [{ data: ships, error: e1 }, { data: checks, error: e2 }] = await Promise.all([
      admin.from('load_shipments').select('*').eq('load_id', loadId).or('check_result.is.null,check_result.neq.applied').order('shipment_nbr'),
      admin.from('check_lines').select('*').eq('load_id', loadId),
    ]);
    if (e1) throw e1;
    if (e2) throw e2;
    const mirror = load.env === 'test' ? 'shipments_test' : 'shipments';

    for (const row of ships ?? []) {
      const nbr = row.shipment_nbr as string;
      let result: 'applied' | 'refused' | 'failed' = 'failed';
      let detail = '';
      let status: string | null = null;
      try {
        await acu.lease();
        const sel = 'ShipmentNbr,Status,ShipVia,ShippedQty,Details/LineNbr,Details/InventoryID,Details/ShippedQty';
        const r = await acu.call('GET', `/Shipment/${encodeURIComponent(nbr)}?$select=${sel}&$expand=Details`);
        if (!r.ok) throw new Error(`couldn't read ${nbr}: ${r.status} ${acuError(r.data)}`);
        const sh = r.data;
        status = v(sh.Status);
        const mine = (checks ?? []).filter(c => c.shipment_nbr === nbr);
        const lines = (sh.Details ?? []).map((d: any) => ({ id: d.id, line: num(v(d.LineNbr)), qty: num(v(d.ShippedQty)) ?? 0, item: v(d.InventoryID) }));

        if (status === 'Confirmed') { result = 'applied'; detail = 'Already confirmed'; }
        else if (!EDITABLE.includes(status!)) { result = 'refused'; detail = `Status is ${status} in Acumatica`; }
        else if (!v(sh.ShipVia)) { result = 'refused'; detail = 'No Ship Via on the shipment (lock in the trucker first)'; }
        else {
          const changed = mine.filter(c => {
            const l = lines.find((x: any) => x.line === c.line_nbr);
            return !l || Number(l.qty) !== Number(c.shipped_qty);
          });
          const finalTotal = lines.reduce((t: number, l: any) => {
            const c = mine.find(x => x.line_nbr === l.line);
            return t + (c ? Number(c.final_qty) : Number(l.qty));
          }, 0);
          if (changed.length) {
            result = 'refused'; detail = `Changed in Acumatica since it was checked (lines ${changed.map(c => c.line_nbr).join(', ')}); check it again`;
          } else if (finalTotal <= 0) {
            result = 'refused'; detail = 'Nothing left to ship on this shipment; cancel it in Acumatica';
          } else {
            const edits = mine.filter(c => Number(c.final_qty) < Number(c.shipped_qty)).map(c => {
              const l = lines.find((x: any) => x.line === c.line_nbr);
              return Number(c.final_qty) === 0 ? { id: l.id, delete: true } : { id: l.id, ShippedQty: { value: Number(c.final_qty) } };
            });
            if (edits.length) {
              const put = await acu.call('PUT', `/Shipment?$expand=Details`, { id: sh.id, Details: edits });
              if (!put.ok) throw new Error(`line changes refused: ${put.status} ${acuError(put.data)}`);
            }
            const ctl = await acu.call('PUT', `/Shipment?$select=${FIELDS}`, { id: sh.id, Hold: { value: false }, ControlQty: { value: finalTotal } });
            if (!ctl.ok) throw new Error(`Control Qty refused: ${ctl.status} ${acuError(ctl.data)}`);
            await acu.confirmShipment(sh.id);
            const after = await acu.getShipment(nbr, false);
            status = after.status;
            if (after.status !== 'Confirmed') throw new Error(`Quantities set, but the shipment is ${after.status}, not Confirmed`);
            result = 'applied';
            detail = edits.length ? `${edits.length} line(s) lowered or removed` : '';
          }
        }
      } catch (e: any) {
        result = 'failed'; detail = String(e?.message ?? e).slice(0, 400);
      }
      results.push({ shipment_nbr: nbr, result, detail });
      await admin.from('load_shipments')
        .update({ check_result: result, check_detail: detail || null, check_at: new Date().toISOString() })
        .eq('env', load.env).eq('shipment_nbr', nbr);
      if (status) await admin.from(mirror).update({ status }).eq('shipment_nbr', nbr);
      if (result === 'applied') {
        // Keep the page's copy of the lines in step until the next sync.
        for (const c of (checks ?? []).filter(c => c.shipment_nbr === nbr && Number(c.final_qty) < Number(c.shipped_qty))) {
          await admin.from('shipment_lines').update({ shipped_qty: c.final_qty }).eq('env', load.env).eq('shipment_nbr', nbr).eq('line_nbr', c.line_nbr);
        }
      }
      await admin.from('loads').update({ check_status: 'confirming' }).eq('id', loadId); // heartbeat
    }
  } catch (e: any) {
    fatal = String(e?.message ?? e);
    console.error('dispatch-acu check_confirm', loadId, e);
  } finally {
    const { data: all } = await admin.from('load_shipments').select('check_result').eq('load_id', loadId);
    const done = !!all?.length && all.every(r => r.check_result === 'applied');
    const nothing = !all?.some(r => r.check_result);
    const check_status = done ? 'confirmed' : (nothing && fatal) ? 'checking' : 'partial';
    await admin.from('loads').update({ check_status }).eq('id', loadId);
    const count = (k: string) => results.filter(r => r.result === k).length;
    await admin.from('load_events').insert({
      load_id: loadId, env: load.env, load_nbr: load.load_nbr, kind: 'check_confirm', outcome: check_status, actor_name: actorName,
      note: fatal ?? `${count('applied')} confirmed, ${count('refused')} refused, ${count('failed')} failed`,
      detail: { results },
    });
  }
  return { ok: !fatal, error: fatal, results };
}

// ------------------------------------------------------------------
// invoicing: Prepare Invoice on Confirmed shipments (the supervisor's bulk screen)
// ------------------------------------------------------------------
// Per shipment: already invoiced -> done; not Confirmed -> refused; otherwise run
// Prepare Invoice and read the status back. Releasing the invoice is Accounts' job.
async function invoiceShipments(env: string, rows: any[], acu: Acu) {
  const mirror = env === 'test' ? 'shipments_test' : 'shipments';
  for (const row of rows) {
    const nbr = row.shipment_nbr as string;
    let state: 'done' | 'refused' | 'failed' = 'failed';
    let detail = '';
    let status: string | null = null;
    try {
      await acu.lease();
      const sh = await acu.getShipment(nbr, false);
      status = sh.status;
      if (status === 'Invoiced' || status === 'Completed') { state = 'done'; detail = 'Already invoiced'; }
      else if (status !== 'Confirmed') { state = 'refused'; detail = `Status is ${status} in Acumatica, not Confirmed`; }
      else {
        await acu.shipmentAction('PrepareInvoice', sh.id);
        const after = await acu.getShipment(nbr, false);
        status = after.status;
        if (status === 'Confirmed') throw new Error('Prepare Invoice ran, but the shipment is still Confirmed');
        state = 'done';
      }
    } catch (e: any) {
      state = 'failed'; detail = String(e?.message ?? e).slice(0, 400);
    }
    const now = new Date().toISOString();
    await admin.from('shipment_invoicing')
      .update({ state, detail: detail || null, finished_at: now, updated_at: now }).eq('env', env).eq('shipment_nbr', nbr);
    if (status) await admin.from(mirror).update({ status }).eq('shipment_nbr', nbr);
  }
}

// Take up to 20 queued shipments (oldest first) and mark them running.
async function claimInvoices(env: string): Promise<any[]> {
  const { data: q, error } = await admin.from('shipment_invoicing').select('shipment_nbr')
    .eq('env', env).eq('state', 'queued').order('requested_at').limit(20);
  if (error) throw error;
  if (!q?.length) return [];
  const { data, error: e2 } = await admin.from('shipment_invoicing')
    .update({ state: 'running', updated_at: new Date().toISOString() })
    .eq('env', env).eq('state', 'queued').in('shipment_nbr', q.map(r => r.shipment_nbr)).select('shipment_nbr');
  if (e2) throw e2;
  return data ?? [];
}

// Mark Confirmed shipments for the drain. Anything else, or already queued, is skipped.
async function requestInvoices(env: string, nbrs: string[], actorName: string) {
  if (env === 'live' && !LIVE_INVOICE_ON)
    return { ok: false, error: 'Invoicing live shipments isn\'t switched on yet (after a TEST run).' };
  targetFor(env);
  const mirror = env === 'test' ? 'shipments_test' : 'shipments';
  const want = [...new Set(nbrs.filter(n => typeof n === 'string' && n))];
  if (!want.length) return { ok: false, error: 'Pick at least one shipment' };
  const { data: ok, error } = await admin.from(mirror).select('shipment_nbr').in('shipment_nbr', want).eq('status', 'Confirmed');
  if (error) throw error;
  const confirmed = (ok ?? []).map(r => r.shipment_nbr as string);
  const { data: busy } = await admin.from('shipment_invoicing').select('shipment_nbr')
    .eq('env', env).in('shipment_nbr', confirmed).in('state', ['queued', 'running']);
  const busySet = new Set((busy ?? []).map(r => r.shipment_nbr));
  const go = confirmed.filter(n => !busySet.has(n));
  if (go.length) {
    const now = new Date().toISOString();
    const { error: e2 } = await admin.from('shipment_invoicing').upsert(
      go.map(n => ({ env, shipment_nbr: n, state: 'queued', detail: null, requested_by: actorName, requested_at: now, finished_at: null, updated_at: now })),
      { onConflict: 'env,shipment_nbr' });
    if (e2) throw e2;
    EdgeRuntime.waitUntil(drain(env).catch(e => console.error('dispatch-acu drain', env, e)));
  }
  return { ok: true, queued: go.length, skipped: want.length - go.length };
}

// ------------------------------------------------------------------
// Queue: apply / check_confirm requests, worked through by drain()
// ------------------------------------------------------------------
declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void };
// Stop taking new loads after this; the cron drain carries on. Background
// work gets 400s wall clock on Pro, and one load can take a minute or two.
const DRAIN_BUDGET_MS = 240_000;

const NOT_WAITING = {
  apply: 'That load isn\'t waiting to be written (already written, or being written now).',
  check: 'That load isn\'t waiting to be confirmed (not checked yet, or already confirming).',
};

// Mark a load for the drain. Refusals the drain would hit anyway (live
// switched off, wrong state) come back now, so the page can say so.
async function requestJob(kind: 'apply' | 'check', loadId: number, actorName: string) {
  const { data: load, error } = await admin.from('loads').select('id, env').eq('id', loadId).maybeSingle();
  if (error) throw error;
  if (!load) return { ok: false, error: 'Load not found' };
  targetFor(load.env);
  if (kind === 'check' && load.env === 'live' && !LIVE_CHECKER_ON)
    return { ok: false, error: 'The checker can\'t confirm live shipments yet (switched on after the pilot load).' };
  const now = new Date().toISOString();
  const q = kind === 'apply'
    ? admin.from('loads').update({ write_requested_at: now, write_requested_by: actorName })
        .eq('id', loadId).in('status', ['confirmed', 'partial'])
    : admin.from('loads').update({ confirm_requested_at: now, confirm_requested_by: actorName })
        .eq('id', loadId).in('status', ['done', 'partial']).in('check_status', ['checking', 'partial']);
  const { data: marked, error: e2 } = await q.select('id');
  if (e2) throw e2;
  if (!marked?.length) return { ok: false, error: NOT_WAITING[kind] };
  EdgeRuntime.waitUntil(drain(load.env).catch(e => console.error('dispatch-acu drain', load.env, e)));
  return { ok: true, queued: true };
}

function queued(env: string) {
  return Promise.all([
    admin.from('loads').select('id, write_requested_at').eq('env', env).in('status', ['confirmed', 'partial'])
      .not('write_requested_at', 'is', null).order('write_requested_at').limit(1),
    admin.from('loads').select('id, confirm_requested_at').eq('env', env).in('status', ['done', 'partial'])
      .in('check_status', ['checking', 'partial']).not('confirm_requested_at', 'is', null).order('confirm_requested_at').limit(1),
    admin.from('shipment_invoicing').select('shipment_nbr').eq('env', env).eq('state', 'queued').limit(1),
  ]).then(([w, c, i]) => {
    if (w.error) throw w.error;
    if (c.error) throw c.error;
    if (i.error) throw i.error;
    return { w: w.data?.[0] ?? null, c: c.data?.[0] ?? null, i: i.data?.[0] ?? null };
  });
}

// Oldest request first. Claiming clears the request, so it runs once, and
// clears the results of shipments not yet through, so progress counts up from 0.
async function claimNext(env: string): Promise<{ kind: 'apply' | 'check'; load: any } | null> {
  for (let tries = 0; tries < 5; tries++) {
    const { w, c } = await queued(env);
    if (!w && !c) return null;
    const kind = w && (!c || w.write_requested_at <= c.confirm_requested_at) ? 'apply' : 'check';
    const id = kind === 'apply' ? w!.id : c!.id;
    const upd = kind === 'apply'
      ? admin.from('loads').update({ status: 'writing', write_requested_at: null })
          .eq('id', id).in('status', ['confirmed', 'partial']).not('write_requested_at', 'is', null)
      : admin.from('loads').update({ check_status: 'confirming', confirm_requested_at: null })
          .eq('id', id).in('check_status', ['checking', 'partial']).not('confirm_requested_at', 'is', null);
    const { data: got, error } = await upd.select('*');
    if (error) throw error;
    if (!got?.length) continue;   // changed under us (e.g. undone); look again
    if (kind === 'apply') await admin.from('load_shipments').update({ result: null, result_detail: null })
      .eq('load_id', id).or('result.is.null,result.neq.applied');
    else await admin.from('load_shipments').update({ check_result: null, check_detail: null })
      .eq('load_id', id).or('check_result.is.null,check_result.neq.applied');
    return { kind, load: got[0] };
  }
  return null;
}

// Only called while holding the target's lease, so no other run is working
// on this env: anything still marked writing / confirming was cut off.
async function recoverOrphans(env: string) {
  const cutoff = new Date(Date.now() - 2 * 60e3).toISOString();
  await admin.from('loads').update({ status: 'partial' }).eq('env', env).eq('status', 'writing').lt('updated_at', cutoff);
  await admin.from('loads').update({ check_status: 'partial' }).eq('env', env).eq('check_status', 'confirming').lt('updated_at', cutoff);
  // Invoicing re-reads the shipment first, so putting a cut-off one back in the queue is safe.
  await admin.from('shipment_invoicing').update({ state: 'queued' }).eq('env', env).eq('state', 'running').lt('updated_at', cutoff);
}

// Acumatica wouldn't let us in: tell every waiting load, rather than retrying
// the sign-in every minute while the pages say "queued".
async function failQueue(env: string, msg: string) {
  await admin.from('shipment_invoicing').update({ state: 'failed', detail: msg.slice(0, 400), finished_at: new Date().toISOString() })
    .eq('env', env).eq('state', 'queued');
  for (;;) {
    const { w, c } = await queued(env);
    if (!w && !c) return;
    const id = (w ?? c)!.id;
    const kind = w ? 'writeback' : 'check_confirm';
    const { data } = await admin.from('loads').update(w ? { write_requested_at: null } : { confirm_requested_at: null })
      .eq('id', id).select('id, env, load_nbr, ship_via, write_requested_by, confirm_requested_by');
    const l = data?.[0];
    if (l) await admin.from('load_events').insert({
      load_id: l.id, env: l.env, load_nbr: l.load_nbr, kind, ship_via: w ? l.ship_via : null,
      outcome: 'failed', actor_name: (w ? l.write_requested_by : l.confirm_requested_by) ?? 'unknown', note: msg,
    });
  }
}

async function drain(env: string) {
  const started = Date.now();
  const t = targetFor(env);
  for (;;) {
    const { w, c, i } = await queued(env);
    if (!w && !c && !i) return;
    const acu = new Acu(t, `queue ${env}`);
    // Busy: the run holding it re-reads the queue after letting go, and the
    // cron drain comes round within a minute either way.
    if (!(await acu.tryLease())) return;
    try {
      await recoverOrphans(env);
      try { await acu.login(); }
      catch (e: any) { await failQueue(env, String(e?.message ?? e)); return; }
      for (;;) {
        if (Date.now() - started > DRAIN_BUDGET_MS) return;
        const job = await claimNext(env);
        if (!job) {
          // Loads first; invoices once none are waiting.
          const inv = await claimInvoices(env);
          if (!inv.length) break;
          await invoiceShipments(env, inv, acu);
          continue;
        }
        if (job.kind === 'apply') await applyLoad(job.load, acu);
        else await checkConfirm(job.load, acu);
      }
    } finally {
      await acu.logout();
    }
  }
}

// ------------------------------------------------------------------
// sync_test: TEST tenant's shipments -> shipments_test
// Through the same REST Shipment entity the writeback uses (the TEST API
// user can see Shipments, not the SO-Shipment GI). Takes every Open, On Hold
// and Confirmed shipment (TEST is an old copy, so no date window) and drops
// rows TEST no longer returns. Customer names come from public.customers
// (production; same customer IDs). One row per shipment, so no roll-up.
//
// Value = sum over the shipment's lines of shipped qty x the order line's
// net unit price (ext_price / order_qty from so_ordered_items, which keeps
// orders back to Jan 2025). Lines whose order line isn't found count as 0.
//
// The lines themselves go to public.shipment_lines (env 'test') for the
// expandable shipment rows: item, description, UOM, ordered vs shipped qty.
// ------------------------------------------------------------------
const SYNC_FIELDS = 'ShipmentNbr,Type,Operation,Status,ShipmentDate,CustomerID,WarehouseID,ShippingZoneID,ShipVia,ShippedQty,ShippedVolume,CreatedDateTime,LastModifiedDateTime,' +
  'Details/LineNbr,Details/InventoryID,Details/Description,Details/UOM,Details/LocationID,' +
  'Details/OrderType,Details/OrderNbr,Details/OrderLineNbr,Details/OrderedQty,Details/ShippedQty';
const SYNC_PAGE = 500;

function num(val: any): number | null {
  if (val == null || val === '') return null;
  const n = Number(val); return isNaN(n) ? null : n;
}

async function syncTest() {
  const t = targetFor('test');
  const syncedAt = new Date().toISOString();
  const acu = new Acu(t, 'sync_test');
  const raw: any[] = [];
  try {
    await acu.login();
    const filter = encodeURIComponent("Status eq 'Open' or Status eq 'On Hold' or Status eq 'Confirmed'");
    for (let skip = 0; ; skip += SYNC_PAGE) {
      await acu.lease();
      const r = await acu.call('GET', `/Shipment?$select=${SYNC_FIELDS}&$expand=Details&$filter=${filter}&$top=${SYNC_PAGE}&$skip=${skip}`);
      if (!r.ok) throw new Error(`${t.label} shipments read failed: ${r.status} ${acuError(r.data)}`);
      const page = Array.isArray(r.data) ? r.data : [];
      raw.push(...page);
      if (page.length < SYNC_PAGE) break;
    }
  } finally {
    await acu.logout();
  }
  if (!raw.length) throw new Error(`${t.label} returned 0 shipments; left shipments_test as it was`);

  // Order line prices for every order these shipments draw from.
  const lines = (s: any) => (Array.isArray(s.Details) ? s.Details : []).map((d: any) => ({
    type: v(d.OrderType), nbr: v(d.OrderNbr), line: num(v(d.OrderLineNbr)), qty: num(v(d.ShippedQty)) ?? 0,
    line_nbr: num(v(d.LineNbr)), inventory_id: v(d.InventoryID), description: v(d.Description), uom: v(d.UOM),
    location_id: v(d.LocationID), ordered: num(v(d.OrderedQty)),
  }));
  const orderNbrs = [...new Set(raw.flatMap(s => lines(s).map(l => l.nbr)).filter(Boolean))];
  const price = new Map<string, number>();
  for (let i = 0; i < orderNbrs.length; i += 200) {
    const { data } = await admin.from('so_ordered_items')
      .select('order_type, order_nbr, line_nbr, order_qty, ext_price, unit_price').in('order_nbr', orderNbrs.slice(i, i + 200));
    (data ?? []).forEach(o => {
      const q = Number(o.order_qty), ext = Number(o.ext_price);
      const unit = q > 0 && !isNaN(ext) ? ext / q : Number(o.unit_price) || 0;
      price.set(`${o.order_type}|${o.order_nbr}|${o.line_nbr}`, unit);
    });
    // Orders copied into TEST by dispatch-test-seed have new numbers that
    // so_ordered_items doesn't know; their log holds the price sent per line.
    const { data: copies } = await admin.from('dispatch_test_orders')
      .select('test_order_nbr, lines').in('test_order_nbr', orderNbrs.slice(i, i + 200));
    (copies ?? []).forEach(c => (c.lines ?? []).forEach((l: any) =>
      price.set(`SO|${c.test_order_nbr}|${l.line}`, Number(l.unit_price) || 0)));
  }

  const rows = raw.map(s => ({
    shipment_nbr: v(s.ShipmentNbr), shipment_type: v(s.Type), operation: v(s.Operation), status: v(s.Status),
    order_type: [...new Set(lines(s).map(l => l.type).filter(Boolean))].join(', ') || null,
    order_nbr: [...new Set(lines(s).map(l => l.nbr).filter(Boolean))].join(', ') || null,
    shipment_value: lines(s).length ? Math.round(lines(s).reduce((t, l) => t + l.qty * (price.get(`${l.type}|${l.nbr}|${l.line}`) ?? 0), 0) * 100) / 100 : null,
    shipment_date: v(s.ShipmentDate)?.split('T')[0] ?? null, customer_id: v(s.CustomerID),
    warehouse_id: v(s.WarehouseID), shipping_zone: v(s.ShippingZoneID), ship_via: v(s.ShipVia),
    shipped_qty: num(v(s.ShippedQty)), shipped_volume: num(v(s.ShippedVolume)),
    created_on: v(s.CreatedDateTime), last_modified_on: v(s.LastModifiedDateTime),
    synced_at: syncedAt,
  } as Record<string, any>)).filter(r => r.shipment_nbr);

  const ids = [...new Set(rows.map(r => r.customer_id).filter(Boolean))];
  const names = new Map<string, string>();
  for (let i = 0; i < ids.length; i += 300) {
    const { data } = await admin.from('customers').select('customer_id, customer_name').in('customer_id', ids.slice(i, i + 300));
    (data ?? []).forEach(c => names.set(c.customer_id, c.customer_name));
  }
  rows.forEach(r => { r.customer_name = names.get(r.customer_id) ?? null; });

  for (let i = 0; i < rows.length; i += 500) {
    const { error } = await admin.from('shipments_test').upsert(rows.slice(i, i + 500), { onConflict: 'shipment_nbr' });
    if (error) throw new Error(`upsert: ${error.message}`);
  }
  const { data: gone, error } = await admin.from('shipments_test').delete().lt('synced_at', syncedAt).select('shipment_nbr');
  if (error) throw new Error(`delete: ${error.message}`);

  // Line items. A shipment's lines are replaced as a set by the upsert + the
  // stale delete below (a line removed in Acumatica drops out).
  const lineRows = raw.flatMap(sh => lines(sh).filter(l => l.line_nbr != null).map(l => {
    const unit = price.get(`${l.type}|${l.nbr}|${l.line}`);
    return {
      env: 'test', shipment_nbr: v(sh.ShipmentNbr), line_nbr: l.line_nbr, inventory_id: l.inventory_id,
      description: l.description, uom: l.uom, ordered_qty: l.ordered, shipped_qty: l.qty,
      order_type: l.type, order_nbr: l.nbr, order_line_nbr: l.line, location_id: l.location_id,
      unit_price: unit ?? null, line_value: unit == null ? null : Math.round(l.qty * unit * 100) / 100,
      synced_at: syncedAt,
    };
  }));
  for (let i = 0; i < lineRows.length; i += 1000) {
    const { error: le } = await admin.from('shipment_lines').upsert(lineRows.slice(i, i + 1000), { onConflict: 'env,shipment_nbr,line_nbr' });
    if (le) throw new Error(`lines upsert: ${le.message}`);
  }
  await admin.from('shipment_lines').delete().eq('env', 'test').lt('synced_at', syncedAt);
  return {
    upserted: rows.length, removed: gone?.length ?? 0, synced_at: syncedAt,
    with_lines: rows.filter(r => r.order_nbr).length, valued: rows.filter(r => r.shipment_value > 0).length,
    lines: lineRows.length,
  };
}

// ------------------------------------------------------------------
// sync_live_lines: production line items for the pages (read-only)
// The production SO-Shipment GI (sync-shipments) has no lines, so value, qty
// detail, short lines, picklists and the checker all read them from here.
// Takes production's Open and On Hold shipments (a day is a few hundred, one
// call per 500), replaces each returned shipment's lines, and leaves the lines
// of shipments that have since been confirmed alone (picking/checking history).
// ------------------------------------------------------------------
const LIVE_LINE_FIELDS = 'ShipmentNbr,Status,' +
  'Details/LineNbr,Details/InventoryID,Details/Description,Details/UOM,Details/LocationID,' +
  'Details/OrderType,Details/OrderNbr,Details/OrderLineNbr,Details/OrderedQty,Details/ShippedQty';

async function syncLiveLines() {
  const t = readTargetFor('live');
  const syncedAt = new Date().toISOString();
  const acu = new Acu(t, 'sync_live_lines');
  const raw: any[] = [];
  try {
    await acu.login();
    const filter = encodeURIComponent("Status eq 'Open' or Status eq 'On Hold'");
    for (let skip = 0; ; skip += SYNC_PAGE) {
      await acu.lease();
      const r = await acu.call('GET', `/Shipment?$select=${LIVE_LINE_FIELDS}&$expand=Details&$filter=${filter}&$top=${SYNC_PAGE}&$skip=${skip}`);
      if (!r.ok) throw new Error(`${t.label} shipments read failed: ${r.status} ${acuError(r.data)}`);
      const page = Array.isArray(r.data) ? r.data : [];
      raw.push(...page);
      if (page.length < SYNC_PAGE) break;
    }
  } finally {
    await acu.logout();
  }

  const lines = (sh: any) => (Array.isArray(sh.Details) ? sh.Details : []).map((d: any) => ({
    type: v(d.OrderType), nbr: v(d.OrderNbr), line: num(v(d.OrderLineNbr)), qty: num(v(d.ShippedQty)) ?? 0,
    line_nbr: num(v(d.LineNbr)), inventory_id: v(d.InventoryID), description: v(d.Description), uom: v(d.UOM),
    location_id: v(d.LocationID), ordered: num(v(d.OrderedQty)),
  }));
  const orderNbrs = [...new Set(raw.flatMap(sh => lines(sh).map(l => l.nbr)).filter(Boolean))];
  const price = new Map<string, number>();
  for (let i = 0; i < orderNbrs.length; i += 200) {
    const { data } = await admin.from('so_ordered_items')
      .select('order_type, order_nbr, line_nbr, order_qty, ext_price, unit_price').in('order_nbr', orderNbrs.slice(i, i + 200));
    (data ?? []).forEach(o => {
      const q = Number(o.order_qty), ext = Number(o.ext_price);
      price.set(`${o.order_type}|${o.order_nbr}|${o.line_nbr}`, q > 0 && !isNaN(ext) ? ext / q : Number(o.unit_price) || 0);
    });
  }

  const lineRows = raw.flatMap(sh => lines(sh).filter(l => l.line_nbr != null).map(l => {
    const unit = price.get(`${l.type}|${l.nbr}|${l.line}`);
    return {
      env: 'live', shipment_nbr: v(sh.ShipmentNbr), line_nbr: l.line_nbr, inventory_id: l.inventory_id,
      description: l.description, uom: l.uom, ordered_qty: l.ordered, shipped_qty: l.qty,
      order_type: l.type, order_nbr: l.nbr, order_line_nbr: l.line, location_id: l.location_id,
      unit_price: unit ?? null, line_value: unit == null ? null : Math.round(l.qty * unit * 100) / 100,
      synced_at: syncedAt,
    };
  }));
  for (let i = 0; i < lineRows.length; i += 1000) {
    const { error } = await admin.from('shipment_lines').upsert(lineRows.slice(i, i + 1000), { onConflict: 'env,shipment_nbr,line_nbr' });
    if (error) throw new Error(`lines upsert: ${error.message}`);
  }
  // Lines removed in Acumatica from a shipment we just read drop out.
  const nbrs = [...new Set(raw.map(sh => v(sh.ShipmentNbr)).filter(Boolean))] as string[];
  for (let i = 0; i < nbrs.length; i += 200) {
    await admin.from('shipment_lines').delete().eq('env', 'live').in('shipment_nbr', nbrs.slice(i, i + 200)).lt('synced_at', syncedAt);
  }

  const values = raw.map(sh => {
    const ls = lines(sh);
    return { shipment_nbr: v(sh.ShipmentNbr), value: ls.length ? Math.round(ls.reduce((t, l) => t + l.qty * (price.get(`${l.type}|${l.nbr}|${l.line}`) ?? 0), 0) * 100) / 100 : null };
  }).filter(x => x.shipment_nbr && x.value != null);
  const { data: updated, error: ve } = await admin.rpc('dispatch_set_values', { p_rows: values });
  if (ve) throw new Error(`values: ${ve.message}`);
  return { shipments: raw.length, lines: lineRows.length, values_set: updated ?? 0, synced_at: syncedAt };
}

// ------------------------------------------------------------------
Deno.serve(async (req) => {
  const headers = { ...cors(req), 'Content-Type': 'application/json' };
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors(req) });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);

  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
  let p: any = {};
  try { p = await req.json(); } catch { /* empty */ }

  // Scheduled jobs with the Vault cron token: the read-only live line sync,
  // and the queue's safety-net drain.
  if (['sync_live_lines', 'drain'].includes(p.action) && token && !token.includes('.')) {
    const { data: ok } = await admin.rpc('dispatch_cron_ok', { p_token: token });
    if (!ok) return json({ ok: false, error: 'bad cron token' }, 401);
    if (p.action === 'drain') {
      for (const env of ['test', 'live']) {
        try { targetFor(env); } catch { continue; }   // live writeback off: nothing can be queued there
        EdgeRuntime.waitUntil(drain(env).catch(e => console.error('dispatch-acu drain (cron)', env, e)));
      }
      return json({ ok: true });
    }
    try { return json({ ok: true, ...(await syncLiveLines()) }); }
    catch (e: any) { console.error('dispatch-acu sync_live_lines (cron)', e); return json({ ok: false, error: String(e?.message ?? e) }, 500); }
  }

  const { data: u, error: uErr } = token ? await admin.auth.getUser(token) : { data: null, error: true } as any;
  if (uErr || !u?.user) return json({ ok: false, error: 'Sign in first' }, 401);
  const { data: roleRows } = await admin.from('dispatch_roles').select('role').eq('user_id', u.user.id);
  const roles = (roleRows ?? []).map(r => r.role);
  if (!roles.length) return json({ ok: false, error: 'Your account has no dispatch role' }, 403);
  const { data: prof } = await admin.from('profiles').select('full_name').eq('id', u.user.id).maybeSingle();
  const actorName = prof?.full_name ?? u.user.email ?? 'unknown';

  try {
    switch (p.action) {
      case 'status':
        return json({ ok: true, test_target: TEST_TARGET, test_label: TARGETS[TEST_TARGET]?.label ?? null,
                      live_writeback: LIVE_ON, live_read: TARGETS.live.readCheck!() === null, udf: UDF_ID, roles });
      case 'sync_test':
        return json({ ok: true, ...(await syncTest()) });
      case 'sync_live_lines':
        return json({ ok: true, ...(await syncLiveLines()) });
      case 'check_confirm': {
        if (!roles.includes('checker')) return json({ ok: false, error: 'Only the checker can confirm loads' }, 403);
        const id = Number(p.load_id);
        if (!id) return json({ ok: false, error: 'load_id is required' }, 400);
        return json(await requestJob('check', id, actorName));
      }
      case 'invoice_request': {
        if (!roles.includes('supervisor')) return json({ ok: false, error: 'Only a supervisor can invoice shipments' }, 403);
        const env = p.env === 'live' ? 'live' : 'test';
        if (!Array.isArray(p.shipments) || p.shipments.length > 300) return json({ ok: false, error: 'shipments (up to 300) is required' }, 400);
        return json(await requestInvoices(env, p.shipments, actorName));
      }
      case 'apply': {
        if (!roles.includes('clerk')) return json({ ok: false, error: 'Only the clerk can write loads to Acumatica' }, 403);
        const id = Number(p.load_id);
        if (!id) return json({ ok: false, error: 'load_id is required' }, 400);
        return json(await requestJob('apply', id, actorName));
      }
      default:
        return json({ ok: false, error: `unknown action ${p.action}` }, 400);
    }
  } catch (e: any) {
    console.error('dispatch-acu', p.action, e);
    return json({ ok: false, error: String(e?.message ?? e) }, 500);
  }
});
