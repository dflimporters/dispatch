// acu-transfer-write: writes a SENT transfer list to Acumatica LIVE as a Sales Order of order type TR
// (the Sales Orders screen, order type TR), ON HOLD. It does NOT use the Inventory Transfers screen.
//
// The TR is a request for Ashenheim, like the one sales support keys by hand. It is created on hold and this
// function never releases it, shows no shipment and moves no stock.
//
// POST JSON { action, list_id? } with the signed-in user's token as Authorization: Bearer <token>
// (checked here with auth.getUser; roles: batcher, supervisor or manager).
//   status            -> whether writing is switched on, order type and warehouses configured.
//   preview {list_id} -> the exact payload that would be sent. Nothing is sent to Acumatica.
//   sample            -> read-only: the most recent TR order with all its fields and first line, to check the
//                        field names (especially the destination warehouse) against a real one.
//   create {list_id}  -> writes it. Refused unless DISPATCH_LIVE_TRANSFER = 'on', the list is live, sent (or
//                        received) and not already written. Looks for an existing TR with the same Customer
//                        Order ref (the list number) first, so a retry can't create a second one.
//
// Field names follow the SalesOrder create already used by dispatch-sub (OrderType, CustomerOrder, Details with
// InventoryID / OrderQty / WarehouseID). The destination warehouse field (TO_WH_FIELD, default ToWarehouseID) is
// UNVERIFIED: run `sample` and fix it before switching on. A wrong field makes Acumatica reject the whole
// request; nothing is half-created.
//
// Secrets: ACU_LIVE_USERNAME / _PASSWORD / _TENANT (falling back to ACU_SHIPVIA_*); optional
// ACU_TRANSFER_ORDER_TYPE (TR), ACU_TRANSFER_FROM_WH (ASHENHIEM), ACU_TRANSFER_TO_WH (71), ACU_TRANSFER_TO_WH_FIELD.
// Shares the live Acumatica lease with dispatch-acu; calls are paced one per second; always signs out.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const BASE = 'https://dflimporters.acumatica.com';
const VERSION = '24.200.001';
const USERNAME = Deno.env.get('ACU_LIVE_USERNAME') ?? Deno.env.get('ACU_SHIPVIA_USERNAME') ?? '';
const PASSWORD = Deno.env.get('ACU_LIVE_PASSWORD') ?? Deno.env.get('ACU_SHIPVIA_PASSWORD') ?? '';
const TENANT = Deno.env.get('ACU_LIVE_TENANT') ?? '';
const ON = Deno.env.get('DISPATCH_LIVE_TRANSFER') === 'on';
const ORDER_TYPE = Deno.env.get('ACU_TRANSFER_ORDER_TYPE') ?? 'TR';
const FROM_WH = Deno.env.get('ACU_TRANSFER_FROM_WH') ?? 'ASHENHIEM';
const TO_WH = Deno.env.get('ACU_TRANSFER_TO_WH') ?? '71';
const TO_WH_FIELD = Deno.env.get('ACU_TRANSFER_TO_WH_FIELD') ?? 'ToWarehouseID';   // UNVERIFIED
const GAP_MS = 1000;
const ROLES = ['batcher', 'supervisor', 'manager'];

const cors = (req: Request) => ({
  'Access-Control-Allow-Origin': req.headers.get('Origin') ?? '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  Vary: 'Origin',
});
const v = (f: any) => { const x = f?.value; return typeof x === 'string' ? (x.trim() || null) : (x ?? null); };
const val = (x: unknown) => ({ value: x });
const flat = (o: any) => Object.fromEntries(Object.entries(o ?? {})
  .filter(([k, x]: any) => x && typeof x === 'object' && 'value' in x && !['custom', 'files', '_links'].includes(k))
  .map(([k, x]: any) => [k, x.value]));
const errText = (d: any) => (typeof d === 'string' ? d : String(d?.exceptionMessage ?? d?.message ?? JSON.stringify(d))).slice(0, 400);

async function loadList(id: number) {
  const { data: list, error } = await admin.from('transfer_lists').select('*').eq('id', id).maybeSingle();
  if (error || !list) throw new Error('Transfer list not found');
  const { data: lines, error: le } = await admin.from('transfer_lines').select('inventory_id,send_qty,included').eq('list_id', id).order('inventory_id');
  if (le) throw new Error(le.message);
  const send = (lines ?? []).filter(l => l.included && Number(l.send_qty) > 0);
  return { list, send };
}

// TR sales order: no customer; source warehouse on every line; destination warehouse on the header.
function payload(list: any, send: any[]) {
  return {
    OrderType: val(ORDER_TYPE),
    CustomerOrder: val(list.list_nbr),
    Description: val(`Portal transfer list ${list.list_nbr}`),
    Hold: val(true),
    [TO_WH_FIELD]: val(TO_WH),
    Details: send.map(l => ({ InventoryID: val(l.inventory_id), OrderQty: val(Number(l.send_qty)), UOM: val('CASE'), WarehouseID: val(FROM_WH) })),
  };
}

let cookie = '', last = 0;
const holder = crypto.randomUUID();
async function pace() { const w = last + GAP_MS - Date.now(); if (w > 0) await new Promise(r => setTimeout(r, w)); last = Date.now(); }
async function acu(method: string, path: string, body?: unknown) {
  await pace();
  const res = await fetch(`${BASE}${path}`, { method, headers: { Cookie: cookie, Accept: 'application/json', 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await res.text();
  let data: any = null; try { data = text ? JSON.parse(text) : null; } catch { data = text.slice(0, 500); }
  return { status: res.status, ok: res.ok, data };
}
async function withSession<T>(job: string, fn: () => Promise<T>): Promise<T> {
  if (!USERNAME || !PASSWORD || !TENANT) throw new Error('Live Acumatica login (ACU_LIVE_* and ACU_LIVE_TENANT) is not set');
  const until = Date.now() + 60_000;
  for (;;) {
    const { data, error } = await admin.rpc('acu_lease_take', { p_target: 'live', p_holder: holder, p_job: job });
    if (error) throw new Error(`lease: ${error.message}`);
    if (data) break;
    if (Date.now() > until) throw new Error('Acumatica is busy with another job. Try again in a minute.');
    await new Promise(r => setTimeout(r, 2000));
  }
  try {
    await pace();
    const login = await fetch(`${BASE}/entity/auth/login`, { method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ name: USERNAME, password: PASSWORD, tenant: TENANT }) });
    if (!login.ok) throw new Error(`Acumatica sign-in failed: ${login.status}`);
    cookie = login.headers.getSetCookie().map(c => c.split(';')[0]).join('; ');
    await login.body?.cancel();
    try { return await fn(); }
    finally { try { await pace(); const lo = await fetch(`${BASE}/entity/auth/logout`, { method: 'POST', headers: { Cookie: cookie } }); await lo.body?.cancel(); } catch { /* ignore */ } }
  } finally { await admin.rpc('acu_lease_drop', { p_target: 'live', p_holder: holder }); }
}

const SO = `/entity/Default/${VERSION}/SalesOrder`;

async function create(listId: number, actor: string) {
  if (!ON) return { ok: false, error: 'Writing transfers to Acumatica is switched off (DISPATCH_LIVE_TRANSFER). Create the TR in Acumatica by hand for now.' };
  const { list, send } = await loadList(listId);
  if (list.env !== 'live') return { ok: false, error: 'Only live lists are written to Acumatica' };
  if (!['sent', 'received'].includes(list.status)) return { ok: false, error: 'Mark the list sent first' };
  if (!send.length) return { ok: false, error: 'The list has nothing to send' };
  // Lock: only a list that was never written, or that failed, can be claimed.
  const { data: claimed } = await admin.from('transfer_lists')
    .update({ acu_state: 'creating', acu_error: null, acu_at: new Date().toISOString(), acu_name: actor })
    .eq('id', listId).or('acu_state.is.null,acu_state.eq.failed').select('id');
  if (!claimed?.length) return { ok: false, error: list.acu_ref ? `Already written as ${list.acu_ref}` : 'A write for this list is already in progress or done' };
  try {
    const ref = await withSession('transfer write', async () => {
      // A retry must not create a second TR: look for one with this Customer Order ref.
      const f = encodeURIComponent(`OrderType eq '${ORDER_TYPE}' and CustomerOrder eq '${list.list_nbr}'`);
      const ex = await acu('GET', `${SO}?$filter=${f}&$select=OrderNbr,Status&$top=1`);
      if (!ex.ok) throw new Error(`Could not look up order type ${ORDER_TYPE} (${ex.status}): ${errText(ex.data)}`);
      if (Array.isArray(ex.data) && ex.data[0]) return String(v(ex.data[0].OrderNbr) ?? 'existing');
      const put = await acu('PUT', `${SO}?$expand=Details`, payload(list, send));
      if (!put.ok) throw new Error(`Acumatica refused the TR: ${errText(put.data)}`);
      return String(v(put.data?.OrderNbr) ?? 'created');
    });
    await admin.from('transfer_lists').update({ acu_state: 'created', acu_ref: ref, acu_error: null, acu_at: new Date().toISOString() }).eq('id', listId);
    return { ok: true, ref };
  } catch (e: any) {
    const msg = String(e?.message ?? e).slice(0, 500);
    await admin.from('transfer_lists').update({ acu_state: 'failed', acu_error: msg, acu_at: new Date().toISOString() }).eq('id', listId);
    return { ok: false, error: msg };
  }
}

Deno.serve(async (req) => {
  const headers = { ...cors(req), 'Content-Type': 'application/json' };
  const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors(req) });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
  let p: any = {}; try { p = await req.json(); } catch { /* empty */ }
  const { data: u, error: uErr } = token ? await admin.auth.getUser(token) : { data: null, error: true } as any;
  if (uErr || !u?.user) return json({ ok: false, error: 'Sign in first' }, 401);
  const { data: roleRows } = await admin.from('dispatch_roles').select('role').eq('user_id', u.user.id);
  if (!(roleRows ?? []).some(r => ROLES.includes(r.role))) return json({ ok: false, error: 'Only a coordinator can write transfers to Acumatica' }, 403);
  const { data: prof } = await admin.from('profiles').select('full_name').eq('id', u.user.id).maybeSingle();
  const actor = prof?.full_name ?? u.user.email ?? 'unknown';
  try {
    switch (p.action) {
      case 'status': return json({ ok: true, enabled: ON, order_type: ORDER_TYPE, from: FROM_WH, to: TO_WH, to_field: TO_WH_FIELD, on_hold: true });
      case 'preview': { const { list, send } = await loadList(Number(p.list_id)); return json({ ok: true, enabled: ON, payload: payload(list, send) }); }
      case 'sample': return json({ ok: true, ...(await withSession('transfer sample', async () => {
        const f = encodeURIComponent(`OrderType eq '${ORDER_TYPE}'`);
        const r = await acu('GET', `${SO}?$filter=${f}&$top=1&$expand=Details`);
        if (!r.ok) return { status: r.status, error: errText(r.data) };
        const o = Array.isArray(r.data) ? r.data[0] : null;
        return o ? { status: r.status, header: flat(o), first_line: flat(o.Details?.[0]), lines: o.Details?.length ?? 0 } : { status: r.status, empty: true };
      })) });
      case 'create': return json(await create(Number(p.list_id), actor));
      default: return json({ ok: false, error: `unknown action ${p.action}` }, 400);
    }
  } catch (e: any) { console.error('acu-transfer-write', p.action, e); return json({ ok: false, error: String(e?.message ?? e) }, 500); }
});
