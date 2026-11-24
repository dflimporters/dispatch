// acu-transfer-probe: READ-ONLY look at Acumatica LIVE to find how Transfers (e.g. 025729-025732)
// can be read through the REST API, before any transfer sync is built. Only GET requests, plus the
// login/logout. Nothing is written.
//
// POST with header x-test-token = SHIPVIA_TEST_TOKEN and a JSON body:
//   {"action":"discover"}                      Which candidate entities exist on this endpoint, with the
//                                              field names of one record each. Start here.
//   {"action":"get","path":"/InventoryTransfer?$top=5&$expand=Details"}
//                                              One GET on a whitelisted entity (path starts with the entity
//                                              name). Use it to pull a transfer by number once discover has
//                                              shown the entity and its key field, e.g.
//                                              "/InventoryTransfer/025730?$expand=Details".
//
// Uses the live API login (ACU_LIVE_USERNAME / _PASSWORD / _TENANT, falling back to ACU_SHIPVIA_*) and shares
// the live Acumatica lease with dispatch-acu, so it waits for any running job. Calls are paced one per second.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const BASE = 'https://dflimporters.acumatica.com';
const VERSION = '24.200.001';
const USERNAME = Deno.env.get('ACU_LIVE_USERNAME') ?? Deno.env.get('ACU_SHIPVIA_USERNAME') ?? '';
const PASSWORD = Deno.env.get('ACU_LIVE_PASSWORD') ?? Deno.env.get('ACU_SHIPVIA_PASSWORD') ?? '';
const TENANT = Deno.env.get('ACU_LIVE_TENANT') ?? '';
const TOKEN = Deno.env.get('SHIPVIA_TEST_TOKEN') ?? '';
const GAP_MS = 1000;

// Entities that might carry a transfer. discover tries each; get only allows these.
const CANDIDATES = ['InventoryTransfer', 'TransferOrder', 'Transfer', 'InventoryReceipt', 'InventoryIssue', 'SalesOrder', 'Shipment'];

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b, null, 2), { status, headers: { 'Content-Type': 'application/json' } });
function sameToken(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
const flat = (o: any) => Object.fromEntries(Object.entries(o ?? {})
  .filter(([k, x]: any) => x && typeof x === 'object' && 'value' in x && !['custom', 'files', '_links'].includes(k))
  .map(([k, x]: any) => [k, x.value]));
const errText = (d: any) => (typeof d === 'string' ? d : String(d?.exceptionMessage ?? d?.message ?? JSON.stringify(d))).slice(0, 300);

let cookie = '', last = 0, calls = 0;
const holder = crypto.randomUUID();
async function pace() { const w = last + GAP_MS - Date.now(); if (w > 0) await new Promise(r => setTimeout(r, w)); last = Date.now(); }
async function get(path: string) {
  await pace(); calls++;
  const res = await fetch(`${BASE}${path}`, { method: 'GET', headers: { Cookie: cookie, Accept: 'application/json' } });
  const text = await res.text();
  let data: any = null; try { data = text ? JSON.parse(text) : null; } catch { data = text.slice(0, 500); }
  return { status: res.status, ok: res.ok, data };
}

async function run(body: any) {
  if (!USERNAME || !PASSWORD || !TENANT) return { ok: false, error: 'Live Acumatica login (ACU_LIVE_* or ACU_SHIPVIA_*, and ACU_LIVE_TENANT) is not set' };
  const action = String(body?.action ?? 'discover');
  const out: Record<string, unknown> = { ok: true, base: BASE, tenant: TENANT, version: VERSION };

  const until = Date.now() + 60_000;
  for (;;) {
    const { data, error } = await admin.rpc('acu_lease_take', { p_target: 'live', p_holder: holder, p_job: 'transfer probe' });
    if (error) return { ok: false, error: `lease: ${error.message}` };
    if (data) break;
    if (Date.now() > until) return { ok: false, error: 'Acumatica busy with another job; try again in a minute' };
    await new Promise(r => setTimeout(r, 2000));
  }
  try {
    await pace();
    const login = await fetch(`${BASE}/entity/auth/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ name: USERNAME, password: PASSWORD, tenant: TENANT }),
    });
    out.login = login.status;
    if (!login.ok) { out.ok = false; out.error = (await login.text()).slice(0, 300); return out; }
    cookie = login.headers.getSetCookie().map(c => c.split(';')[0]).join('; ');
    await login.body?.cancel();

    try {
      if (action === 'get') {
        const p = String(body?.path ?? '');
        const m = p.match(/^\/([A-Za-z]+)(?=[/?]|$)/);
        if (!m || !CANDIDATES.includes(m[1])) { out.ok = false; out.error = `path must start with one of: ${CANDIDATES.map(c => '/' + c).join(', ')}`; return out; }
        const r = await get(`/entity/Default/${VERSION}${p}`);
        out.status = r.status;
        out.data = r.ok ? JSON.stringify(r.data).slice(0, 14000) : errText(r.data);
        return out;
      }
      // discover: which entities answer, and what a record looks like
      const ep = await get('/entity');
      const names = ep.ok ? (ep.data?.endpoints ?? []).map((e: any) => `${e.name}/${e.version}`) : { status: ep.status };
      out.endpoints = names;
      const found: Record<string, unknown> = {};
      for (const c of CANDIDATES) {
        const r = await get(`/entity/Default/${VERSION}/${c}?$top=1`);
        if (!r.ok) { found[c] = { status: r.status, error: errText(r.data) }; continue; }
        const first = Array.isArray(r.data) ? r.data[0] : null;
        found[c] = first ? { status: r.status, fields: Object.keys(first).filter(k => !['id', 'rowNumber', 'note', 'custom', '_links', 'files'].includes(k)), sample: flat(first) }
                         : { status: r.status, empty: true };
      }
      out.candidates = found;
      return out;
    } finally {
      await pace(); calls++;
      const lo = await fetch(`${BASE}/entity/auth/logout`, { method: 'POST', headers: { Cookie: cookie } });
      out.logout = lo.status; await lo.body?.cancel();
    }
  } finally {
    out.calls = calls;
    await admin.rpc('acu_lease_drop', { p_target: 'live', p_holder: holder });
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  if (!TOKEN || !sameToken(req.headers.get('x-test-token') ?? '', TOKEN)) return json({ ok: false, error: 'bad or missing x-test-token' }, 401);
  let body: any = {};
  try { body = await req.json(); } catch { /* default action */ }
  try { const r = await run(body); return json(r, (r as any).ok === false ? 500 : 200); }
  catch (e) { return json({ ok: false, error: String(e) }, 500); }
});
