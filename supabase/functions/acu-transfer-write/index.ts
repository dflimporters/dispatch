// acu-transfer-write: writes a SENT transfer list to Acumatica LIVE as a Transfer, ON HOLD.
//
// The Transfer is a request for Ashenheim, like the one sales support keys by hand (e.g. 025729). It is created
// on hold and this function never releases it, so no stock moves because of it.
//
// POST JSON { action, list_id? } with the signed-in user's token as Authorization: Bearer <token>
// (checked here with auth.getUser; roles: batcher, supervisor or manager).
//   status           -> whether writing is switched on, which entity and warehouses are configured.
//   preview {list_id} -> the exact payload that would be sent. Nothing is sent to Acumatica.
//   schema           -> read-only: the entity's field list ($adHocSchema), to check the field names below.
//   create {list_id} -> writes it. Refused unless DISPATCH_LIVE_TRANSFER = 'on', the list is live, sent (or
//                       received) and not already created. Looks for an existing Transfer with the same
//                       external ref first, so a retry can't create a second one.
//
// UNVERIFIED: the entity name and field names in FIELDS were written without seeing the live endpoint.
// Run acu-transfer-probe {"action":"discover"} and this function's `schema`, fix FIELDS / ACU_TRANSFER_ENTITY,
// and test with `preview` before switching DISPATCH_LIVE_TRANSFER on. A wrong field makes Acumatica reject the
// whole request; nothing is half-created.
//
// Secrets: ACU_LIVE_USERNAME / _PASSWORD / _TENANT (falling back to ACU_SHIPVIA_*), optional
// ACU_TRANSFER_ENTITY, ACU_TRANSFER_FROM_WH, ACU_TRANSFER_TO_WH, ACU_TRANSFER_FROM_LOC, ACU_TRANSFER_TO_LOC.
// Shares the live Acumatica lease with dispatch-acu; calls are paced one per second; always signs out.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const BASE = 'https://dflimporters.acumatica.com';
const VERSION = '24.200.001';
const USERNAME = Deno.env.get('ACU_LIVE_USERNAME') ?? Deno.env.get('ACU_SHIPVIA_USERNAME') ?? '';
const PASSWORD = Deno.env.get('ACU_LIVE_PASSWORD') ?? Deno.env.get('ACU_SHIPVIA_PASSWORD') ?? '';
const TENANT = Deno.env.get('ACU_LIVE_TENANT') ?? '';
const ON = Deno.env.get('DISPATCH_LIVE_TRANSFER') === 'on';
const ENTITY = Deno.env.get('ACU_TRANSFER_ENTITY') ?? 'InventoryTransfer';
const FROM_WH = Deno.env.get('ACU_TRANSFER_FROM_WH') ?? 'ASHENHIEM';
const TO_WH = Deno.env.get('ACU_TRANSFER_TO_WH') ?? '71';
const FROM_LOC = Deno.env.get('ACU_TRANSFER_FROM_LOC') ?? 'AISLE01';   // as in the transfers Ashenheim sent (025730-025732)
const TO_LOC = Deno.env.get('ACU_TRANSFER_TO_LOC') ?? 'Y01';
const UOM = 'CASE';
const GAP_MS = 1000;
const ROLES = ['batcher', 'supervisor', 'manager'];

// Field names on the Acumatica entity. UNVERIFIED, see above.
const FIELDS = { date: 'Date', description: 'Description', extRef: 'ExternalRef', hold: 'Hold', fromWh: 'FromWarehouseID', toWh: 'ToWarehouseID',
                 details: 'Details', item: 'InventoryID', qty: 'Quantity', uom: 'UOM', fromLoc: 'FromLocationID', toLoc: 'ToLocationID', ref: 'ReferenceNbr' };

const cors = (req: Request) => ({
  'Access-Control-Allow-Origin': req.headers.get('Origin') ?? '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  Vary: 'Origin',
});
const v = (f: any) => { const x = f?.value; return typeof x === 'string' ? (x.trim() || null) : (x ?? null); };
const val = (x: unknown) => ({ value: x });
const errText = (d: any) => (typeof d === 'string' ? d : String(d?.exceptionMessage ?? d?.message ?? JSON.stringify(d))).slice(0, 400);

async function loadList(id: number) {
  const { data: list, error } = await admin.from('transfer_lists').select('*').eq('id', id).maybeSingle();
  if (error || !list) throw new Error('Transfer list not found');
  const { data: lines, error: le } = await admin.from('transfer_lines').select('inventory_id,send_qty,included').eq('list_id', id).order('inventory_id');
  if (le) throw new Error(le.message);
  const send = (lines ?? []).filter(l => l.included && Number(l.send_qty) > 0);
  return { list, send };
}

function payload(list: any, send: any[]) {
  const today = new Date(new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Jamaica' }).format(new Date()) + 'T00:00:00-05:00').toISOString();
  return {
    [FIELDS.date]: val(today),
    [FIELDS.description]: val(`Portal transfer list ${list.list_nbr}`),
    [FIELDS.extRef]: val(list.list_nbr),
    [FIELDS.hold]: val(true),
    [FIELDS.fromWh]: val(FROM_WH),
    [FIELDS.toWh]: val(TO_WH),
    [FIELDS.details]: send.map(l => ({
      [FIELDS.item]: val(l.inventory_id), [FIELDS.qty]: val(Number(l.send_qty)), [FIELDS.uom]: val(UOM),
      [FIELDS.fromLoc]: val(FROM_LOC), [FIELDS.toLoc]: val(TO_LOC),
    })),
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

async function create(listId: number, actor: string) {
  if (!ON) return { ok: false, error: 'Writing transfers to Acumatica is switched off (DISPATCH_LIVE_TRANSFER). Create it in Acumatica by hand for now.' };
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
      const probe = await acu('GET', `/entity/Default/${VERSION}/${ENTITY}?$top=1`);
      if (!probe.ok) throw new Error(`Entity ${ENTITY} is not available on this endpoint (${probe.status}). Check ACU_TRANSFER_ENTITY.`);
      // A retry must not create a second Transfer: look for one with this external ref.
      const ex = await acu('GET', `/entity/Default/${VERSION}/${ENTITY}?$filter=${FIELDS.extRef} eq '${list.list_nbr}'&$top=1`);
      if (ex.ok && Array.isArray(ex.data) && ex.data[0]) return String(v(ex.data[0][FIELDS.ref]) ?? 'existing');
      const put = await acu('PUT', `/entity/Default/${VERSION}/${ENTITY}?$expand=${FIELDS.details}`, payload(list, send));
      if (!put.ok) throw new Error(`Acumatica refused the transfer: ${errText(put.data)}`);
      return String(v(put.data?.[FIELDS.ref]) ?? 'created');
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
      case 'status': return json({ ok: true, enabled: ON, entity: ENTITY, from: `${FROM_WH}/${FROM_LOC}`, to: `${TO_WH}/${TO_LOC}`, on_hold: true });
      case 'preview': { const { list, send } = await loadList(Number(p.list_id)); return json({ ok: true, enabled: ON, entity: ENTITY, payload: payload(list, send) }); }
      case 'schema': return json({ ok: true, ...(await withSession('transfer schema', async () => { const r = await acu('GET', `/entity/Default/${VERSION}/${ENTITY}/$adHocSchema`); return { status: r.status, schema: r.ok ? r.data : errText(r.data) }; })) });
      case 'create': return json(await create(Number(p.list_id), actor));
      default: return json({ ok: false, error: `unknown action ${p.action}` }, 400);
    }
  } catch (e: any) { console.error('acu-transfer-write', p.action, e); return json({ ok: false, error: String(e?.message ?? e) }, 500); }
});
