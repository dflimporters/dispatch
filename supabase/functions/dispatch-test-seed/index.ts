// Supabase Edge Function: dispatch-test-seed
// TEST-TENANT ONLY. Copies a real day's SO orders (from public.so_ordered_items)
// into the Acumatica TEST tenant as new SO orders, releases holds, and runs
// Create Shipment, so the dispatch portal has realistic volume to batch.
//
// Refuses unless ACU_SHIPVIA_TENANT is exactly 'TEST'. Every call needs header
// x-test-token = SHIPVIA_TEST_TOKEN (same token as acu-shipvia-test). It is run
// by hand (curl), not from the pages.
//
// POST JSON { mode, ... }:
//   probe                                   read-only: SalesOrder actions TEST offers + one existing order
//   seed { source_date, ship_date, limit }  copy up to `limit` not-yet-copied orders from source_date
//   status { source_date }                  what's been copied so far
//   get { path }                            read-only debugging: one GET on the TEST entity endpoint
//   cancel { test_order_nbrs }              undo copies: delete their On Hold/Open shipments, cancel
//                                           the orders, and clear their log rows (so they can be recopied).
//                                           Only orders in dispatch_test_orders can be cancelled.
//
// Each copied order is logged in public.dispatch_test_orders (source -> TEST
// order, shipments, the lines and prices sent), so nothing is copied twice and
// the copies can be found and cancelled later. Orders are tagged in
// Description: "DISPATCH-TEST copy of SO <nbr> (<date>)".
// Customers or items that don't exist in TEST (TEST is an older copy) are
// skipped and reported rather than failing the order.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const BASE   = 'https://dflimporters.acumatica.com';
const ENTITY = `${BASE}/entity/Default/24.200.001`;
const USERNAME = Deno.env.get('ACU_SHIPVIA_USERNAME') ?? '';
const PASSWORD = Deno.env.get('ACU_SHIPVIA_PASSWORD') ?? '';
const TENANT   = Deno.env.get('ACU_SHIPVIA_TENANT') ?? '';
const TOKEN    = Deno.env.get('SHIPVIA_TEST_TOKEN') ?? '';
const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body, null, 2), { status, headers: { 'Content-Type': 'application/json' } });

function v(field: any): any {
  const x = field?.value;
  return typeof x === 'string' ? (x.trim() || null) : (x ?? null);
}
function acuError(data: any): string {
  if (!data) return 'no detail';
  if (typeof data === 'string') return data.slice(0, 400);
  const inner = data.innerException ? ` | ${acuError(data.innerException)}` : '';
  return String(data.exceptionMessage ?? data.message ?? JSON.stringify(data)).slice(0, 400) + inner;
}
function sameToken(a: string, b: string): boolean {
  if (!a || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
const q = (s: string) => `'${String(s).replace(/'/g, "''")}'`;

class Acu {
  cookie = '';
  async login() {
    const res = await fetch(`${BASE}/entity/auth/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ name: USERNAME, password: PASSWORD, tenant: TENANT }),
    });
    if (!res.ok) throw new Error(`login failed: ${res.status} ${(await res.text()).slice(0, 300)}`);
    this.cookie = res.headers.getSetCookie().map(c => c.split(';')[0]).join('; ');
    await res.body?.cancel();
  }
  async logout() {
    if (!this.cookie) return;
    try { const r = await fetch(`${BASE}/entity/auth/logout`, { method: 'POST', headers: { Cookie: this.cookie } }); await r.body?.cancel(); }
    catch (e) { console.error('logout failed', e); }
  }
  async call(method: string, url: string, body?: unknown) {
    const res = await fetch(url.startsWith('http') ? url : `${ENTITY}${url}`, {
      method, headers: { Cookie: this.cookie, Accept: 'application/json', 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let data: any = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = text.slice(0, 3000); }
    return { status: res.status, ok: res.ok, data, location: res.headers.get('Location') };
  }
  // Contract-based actions answer 202 + Location while running, 204 when done.
  async action(path: string, body: unknown) {
    const r = await this.call('POST', path, body);
    if (r.status === 204 || r.status === 200) return;
    if (r.status !== 202 || !r.location) throw new Error(`${path} refused: ${r.status} ${acuError(r.data)}`);
    const loc = r.location.startsWith('http') ? r.location : `${BASE}${r.location}`;
    for (let i = 0; i < 60; i++) {
      await new Promise(res => setTimeout(res, 1000));
      const p = await this.call('GET', loc);
      if (p.status === 204 || p.status === 200) return;
      if (p.status !== 202) throw new Error(`${path} failed: ${p.status} ${acuError(p.data)}`);
    }
    throw new Error(`${path} still running after 60s`);
  }
  // Which of `ids` exist, via $filter on one field (batches of 25).
  async existing(entity: string, field: string, ids: string[]): Promise<Set<string>> {
    const found = new Set<string>();
    for (let i = 0; i < ids.length; i += 25) {
      const f = ids.slice(i, i + 25).map(id => `${field} eq ${q(id)}`).join(' or ');
      const r = await this.call('GET', `/${entity}?$select=${field}&$filter=${encodeURIComponent(f)}`);
      if (!r.ok) throw new Error(`${entity} lookup failed: ${r.status} ${acuError(r.data)}`);
      (r.data ?? []).forEach((x: any) => found.add(v(x[field])));
    }
    return found;
  }
}

// ------------------------------------------------------------------
async function probe(acu: Acu) {
  const sw = await fetch(`${ENTITY}/swagger.json`, { headers: { Cookie: acu.cookie, Accept: 'application/json' } });
  let actions: string[] = [], orderFields: string[] = [], detailFields: string[] = [];
  let actionParams: Record<string, string[]> | null = null;
  if (sw.ok) {
    const s = await sw.json();
    actions = Object.keys(s.paths ?? {}).filter(p => /^\/SalesOrder\/[A-Z]/.test(p));
    const defs = s.definitions ?? s.components?.schemas ?? {};
    orderFields = Object.keys(defs.SalesOrder?.properties ?? {});
    detailFields = Object.keys(defs.SalesOrderDetail?.properties ?? {});
    actionParams = Object.fromEntries(Object.keys(defs).filter(k => /^(SalesOrderCreateShipment|ReleaseFromCreditHold|RemoveHold|CreateShipment)/i.test(k))
      .map(k => [k, Object.keys(defs[k]?.properties?.parameters?.properties ?? defs[k]?.properties ?? {})]));
  } else {
    await sw.body?.cancel();
  }
  const one = await acu.call('GET', `/SalesOrder?$filter=${encodeURIComponent("OrderType eq 'SO'")}&$top=1&$expand=Details`);
  const o = Array.isArray(one.data) ? one.data[0] : null;
  const flat = (x: any) => x && Object.fromEntries(Object.entries(x).filter(([k]) => !['_links', 'custom'].includes(k))
    .map(([k, val]: any) => [k, val && typeof val === 'object' && 'value' in val ? val.value : Array.isArray(val) ? `[${val.length}]` : typeof val === 'object' ? '{}' : val]));
  return {
    ok: true, tenant: TENANT, swagger: sw.status, actions, orderFields, detailFields, actionParams,
    sampleOrder: flat(o), sampleLine: flat(o?.Details?.[0]), readStatus: one.status,
  };
}

// ------------------------------------------------------------------
type Line = { line_nbr: number; inventory_id: string; qty: number; unit_price: number };

async function sourceOrders(sourceDate: string) {
  const rows: any[] = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await admin.from('so_ordered_items')
      .select('order_nbr, line_nbr, customer_id, order_status, inventory_id, order_qty, ext_price, unit_price')
      .eq('order_type', 'SO').eq('order_date', sourceDate).neq('order_status', 'Canceled')
      .order('order_nbr').order('line_nbr').range(from, from + 999);
    if (error) throw error;
    rows.push(...(data ?? []));
    if ((data ?? []).length < 1000) break;
  }
  const by = new Map<string, { order_nbr: string; customer_id: string; lines: Line[] }>();
  for (const r of rows) {
    if (!by.has(r.order_nbr)) by.set(r.order_nbr, { order_nbr: r.order_nbr, customer_id: r.customer_id, lines: [] });
    const qty = Number(r.order_qty) || 0;
    if (qty <= 0 || !r.inventory_id) continue;
    const ext = Number(r.ext_price);
    by.get(r.order_nbr)!.lines.push({
      line_nbr: r.line_nbr, inventory_id: String(r.inventory_id).trim(), qty,
      unit_price: Math.round((qty > 0 && !isNaN(ext) ? ext / qty : Number(r.unit_price) || 0) * 10000) / 10000,
    });
  }
  return [...by.values()];
}

async function log(row: Record<string, unknown>) {
  const { error } = await admin.from('dispatch_test_orders').upsert({ ...row, updated_at: new Date().toISOString() }, { onConflict: 'source_order_nbr' });
  if (error) console.error('log failed', error);
}

async function seed(acu: Acu, sourceDate: string, shipDate: string, limit: number) {
  const { data: done } = await admin.from('dispatch_test_orders').select('source_order_nbr').eq('source_date', sourceDate);
  const skip = new Set((done ?? []).map(d => d.source_order_nbr));
  const todo = (await sourceOrders(sourceDate)).filter(o => !skip.has(o.order_nbr) && o.lines.length).slice(0, limit);
  if (!todo.length) return { ok: true, message: 'nothing left to copy for that date', results: [] };

  // Customers are checked up front. Items aren't: TEST's Stock Items screen
  // hides most items from the API user even though orders accept them, so
  // lines are sent as-is and any item Acumatica rejects is dropped and retried.
  const custOk = await acu.existing('Customer', 'CustomerID', [...new Set(todo.map(o => o.customer_id))]);

  const results: any[] = [];
  for (const src of todo) {
    const base = { source_order_nbr: src.order_nbr, source_date: sourceDate, ship_date: shipDate };
    const steps: string[] = [];
    let nbr: string | null = null;
    try {
      if (!custOk.has(src.customer_id)) {
        await log({ ...base, status: 'skipped', detail: `customer ${src.customer_id} not in TEST` });
        results.push({ source: src.order_nbr, status: 'skipped', detail: `customer ${src.customer_id} not in TEST` });
        continue;
      }
      // 1. Create the order. A rejected item (named in the error, or flagged on
      // its line) is dropped and the order sent again; a failed PUT saves nothing.
      let lines = src.lines.slice();
      const missing: string[] = [];
      let put: any = null;
      for (let tries = 0; tries < 10 && lines.length; tries++) {
        put = await acu.call('PUT', `/SalesOrder?$expand=Details`, {
          OrderType: { value: 'SO' },
          CustomerID: { value: src.customer_id },
          Date: { value: shipDate },
          RequestedOn: { value: shipDate },
          Description: { value: `DISPATCH-TEST copy of SO ${src.order_nbr} (${sourceDate})` },
          Details: lines.map(l => ({
            InventoryID: { value: l.inventory_id }, OrderQty: { value: l.qty },
            UnitPrice: { value: l.unit_price }, ManualPrice: { value: true },
          })),
        });
        if (put.ok) break;
        // Only an "item can't be found" error drops a line; anything else fails
        // the order with Acumatica's own message.
        const NOT_FOUND = /cannot be found|can't be found|not found|does not exist|doesn't exist/i;
        const text = JSON.stringify(put.data ?? '');
        const flagged = Array.isArray(put.data?.Details)
          ? put.data.Details.filter((d: any) => NOT_FOUND.test(String(d?.InventoryID?.error ?? ''))).map((d: any) => v(d.InventoryID)) : [];
        // Lines Acumatica flags with an error of their own (e.g. "Unit conversion
        // is missing" on an item TEST hasn't set up) are dropped with the reason.
        // Details come back in the order they were sent.
        const lineErr = (d: any) => d?.error || Object.values(d ?? {}).map((f: any) => f?.error).find(Boolean);
        const flaggedIdx = Array.isArray(put.data?.Details)
          ? put.data.Details.map((d: any, i: number) => lineErr(d) ? i : -1).filter((i: number) => i >= 0) : [];
        const bad = lines.filter((l, i) => flaggedIdx.includes(i) || flagged.includes(l.inventory_id) ||
          (NOT_FOUND.test(text) && (text.includes(`'${l.inventory_id}'`) || text.includes(`\\"${l.inventory_id}\\"`))));
        if (!bad.length) throw new Error(`create order: ${put.status} ${acuError(put.data)}`);
        const why = new Map(put.data?.Details?.map((d: any, i: number) => [lines[i]?.inventory_id, String(lineErr(d) ?? 'not found')]) ?? []);
        const badIds = new Set(bad.map(l => l.inventory_id));
        missing.push(...[...badIds].map(id => `${id} (${why.get(id) ?? 'not found'})`));
        lines = lines.filter(l => !badIds.has(l.inventory_id));
      }
      if (!lines.length) {
        await log({ ...base, status: 'skipped', detail: `no usable lines in TEST: ${missing.join(', ')}` });
        results.push({ source: src.order_nbr, status: 'skipped', detail: `no usable lines in TEST: ${missing.join(', ')}` });
        continue;
      }
      if (!put?.ok) throw new Error(`create order: ${put?.status} ${acuError(put?.data)}`);
      if (missing.length) steps.push(`${missing.length} line(s) dropped: ${missing.join(', ')}`);
      const id = put.data?.id;
      nbr = v(put.data?.OrderNbr);
      let status = v(put.data?.Status);
      steps.push(`created ${nbr} (${status})`);
      const sent = (put.data?.Details ?? []).map((d: any) => ({
        line: v(d.LineNbr), inventory_id: v(d.InventoryID), qty: v(d.OrderQty), unit_price: v(d.UnitPrice),
      }));
      await log({ ...base, test_order_nbr: nbr, status: 'created', lines: sent, detail: steps.join(' · ') });

      // 2. Holds. TEST's endpoint has no RemoveHold: "On Hold" -> set Control
      // Total = order total (in case totals are validated), then OpenSalesOrder,
      // falling back to clearing Hold. "Credit Hold" -> ReleaseFromCreditHoldSalesOrder.
      const read = async () => v((await acu.call('GET', `/SalesOrder/SO/${encodeURIComponent(nbr!)}?$select=Status`)).data?.Status);
      if (status === 'On Hold') {
        const ct = await acu.call('PUT', `/SalesOrder`, { id, ControlTotal: { value: v(put.data?.OrderTotal) ?? 0 } });
        if (!ct.ok) steps.push(`control total not set: ${acuError(ct.data)}`);
        try { await acu.action('/SalesOrder/OpenSalesOrder', { entity: { id } }); }
        catch (e: any) {
          const r = await acu.call('PUT', `/SalesOrder`, { id, Hold: { value: false } });
          if (!r.ok) throw new Error(`remove hold: ${e.message} / ${acuError(r.data)}`);
        }
        status = await read(); steps.push(`hold removed (${status})`);
      }
      if (status === 'Credit Hold') {
        await acu.action('/SalesOrder/ReleaseFromCreditHoldSalesOrder', { entity: { id } });
        status = await read(); steps.push(`credit hold released (${status})`);
      }
      if (status !== 'Open') throw new Error(`order is ${status}, not Open, so it can't ship`);

      // 3. Create Shipment for the ship date.
      await acu.action('/SalesOrder/SalesOrderCreateShipment', {
        entity: { id }, parameters: { ShipmentDate: { value: shipDate } },
      });
      const after = await acu.call('GET', `/SalesOrder/SO/${encodeURIComponent(nbr!)}?$expand=Shipments`);
      const ships = [...new Set((after.data?.Shipments ?? []).map((s: any) => v(s.ShipmentNbr)).filter(Boolean))] as string[];
      steps.push(`shipment ${ships.join(', ') || 'none'} (order ${v(after.data?.Status)})`);
      await log({ ...base, test_order_nbr: nbr, status: ships.length ? 'shipped' : 'created', shipment_nbrs: ships, lines: sent, detail: steps.join(' · ') });
      results.push({ source: src.order_nbr, test: nbr, status: ships.length ? 'shipped' : 'created', shipments: ships, steps });
    } catch (e: any) {
      steps.push(String(e?.message ?? e));
      await log({ ...base, test_order_nbr: nbr, status: 'failed', detail: steps.join(' · ') });
      results.push({ source: src.order_nbr, test: nbr, status: 'failed', steps });
    }
  }
  return { ok: true, tenant: TENANT, results };
}

// ------------------------------------------------------------------
async function cancel(acu: Acu, nbrs: string[]) {
  const { data: logged } = await admin.from('dispatch_test_orders').select('source_order_nbr, test_order_nbr').in('test_order_nbr', nbrs);
  const ours = new Map((logged ?? []).map(r => [r.test_order_nbr, r.source_order_nbr]));
  const results: any[] = [];
  for (const nbr of nbrs) {
    if (!ours.has(nbr)) { results.push({ order: nbr, status: 'refused', detail: 'not a dispatch-test-seed copy' }); continue; }
    const steps: string[] = [];
    try {
      const o = await acu.call('GET', `/SalesOrder/SO/${encodeURIComponent(nbr)}?$expand=Shipments`);
      if (!o.ok) throw new Error(`read order: ${o.status} ${acuError(o.data)}`);
      if (!/DISPATCH-TEST/.test(v(o.data?.Description) ?? '')) throw new Error('order description has no DISPATCH-TEST tag; left alone');
      for (const sh of [...new Set((o.data?.Shipments ?? []).map((x: any) => v(x.ShipmentNbr)).filter(Boolean))] as string[]) {
        const g = await acu.call('GET', `/Shipment/${encodeURIComponent(sh)}?$select=ShipmentNbr,Status`);
        const st = v(g.data?.Status);
        if (!['On Hold', 'Open'].includes(st)) throw new Error(`shipment ${sh} is ${st}; only On Hold/Open shipments are deleted`);
        const d = await acu.call('DELETE', `/Shipment/${g.data.id}`);
        if (!d.ok) throw new Error(`delete shipment ${sh}: ${d.status} ${acuError(d.data)}`);
        steps.push(`shipment ${sh} deleted`);
      }
      await acu.action('/SalesOrder/CancelSalesOrder', { entity: { id: o.data.id } });
      steps.push('order cancelled');
      await admin.from('dispatch_test_orders').delete().eq('test_order_nbr', nbr);
      await admin.from('shipments_test').delete().in('shipment_nbr', steps.filter(x => x.startsWith('shipment ')).map(x => x.split(' ')[1]));
      results.push({ order: nbr, source: ours.get(nbr), status: 'cancelled', steps });
    } catch (e: any) {
      steps.push(String(e?.message ?? e));
      results.push({ order: nbr, source: ours.get(nbr), status: 'failed', steps });
    }
  }
  return { ok: true, tenant: TENANT, results };
}

// ------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  if (TENANT !== 'TEST') return json({ ok: false, error: `refusing: ACU_SHIPVIA_TENANT is '${TENANT}', not 'TEST'` }, 403);
  if (!TOKEN || !sameToken(req.headers.get('x-test-token') ?? '', TOKEN)) return json({ ok: false, error: 'bad or missing x-test-token' }, 401);
  let p: any = {};
  try { p = await req.json(); } catch { /* empty */ }

  if (p.mode === 'status') {
    const { data } = await admin.from('dispatch_test_orders').select('*').eq('source_date', p.source_date).order('created_at');
    return json({ ok: true, rows: data });
  }

  const acu = new Acu();
  try {
    await acu.login();
    if (p.mode === 'probe') return json(await probe(acu));
    if (p.mode === 'cancel') return json(await cancel(acu, (Array.isArray(p.test_order_nbrs) ? p.test_order_nbrs : []).map(String).slice(0, 15)));
    if (p.mode === 'get') {
      // Read-only debugging: one GET against the TEST entity endpoint.
      const path = String(p.path ?? '');
      if (!path.startsWith('/')) return json({ ok: false, error: 'path must start with /' }, 400);
      const r = await acu.call('GET', path);
      return json({ status: r.status, count: Array.isArray(r.data) ? r.data.length : null, data: Array.isArray(r.data) ? r.data.slice(0, p.show ?? 3) : r.data });
    }
    if (p.mode === 'items') {
      // Read-only: why an item lookup misses. One direct GET per id, plus the batch filter.
      const ids: string[] = (p.ids ?? []).slice(0, 5);
      const one: any = {};
      for (const id of ids) {
        const r = await acu.call('GET', `/StockItem/${encodeURIComponent(id)}?$select=InventoryID,ItemStatus`);
        one[id] = { status: r.status, id: v(r.data?.InventoryID), itemStatus: v(r.data?.ItemStatus), err: r.ok ? null : acuError(r.data) };
      }
      const f = ids.map(id => `InventoryID eq ${q(id)}`).join(' or ');
      const batch = await acu.call('GET', `/StockItem?$select=InventoryID&$filter=${encodeURIComponent(f)}`);
      return json({ one, batchStatus: batch.status, batch: Array.isArray(batch.data) ? batch.data.map((x: any) => v(x.InventoryID)) : acuError(batch.data) });
    }
    if (p.mode === 'seed') {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(p.source_date ?? '') || !/^\d{4}-\d{2}-\d{2}$/.test(p.ship_date ?? ''))
        return json({ ok: false, error: 'source_date and ship_date (YYYY-MM-DD) are required' }, 400);
      return json(await seed(acu, p.source_date, p.ship_date, Math.min(Number(p.limit) || 5, 15)));
    }
    return json({ ok: false, error: `unknown mode ${p.mode}` }, 400);
  } catch (e: any) {
    console.error('dispatch-test-seed', e);
    return json({ ok: false, error: String(e?.message ?? e) }, 500);
  } finally {
    await acu.logout();
  }
});
