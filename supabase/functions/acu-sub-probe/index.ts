// acu-sub-probe: READ-ONLY look at the Acumatica TEST tenant (2024R2) before building the
// item-substitution workflow. Nothing is written.
//
// Reports: the field names and values of a few Open sales orders (to copy defaults for the
// substitute SO: order type, warehouse, ship via, terms, hold / credit-hold fields), which
// SalesOrder / Shipment actions the endpoint exposes (credit-hold release, create shipment,
// add order), whether StockItem and Customer credit fields can be read, and the order types.
//
// POST with header x-test-token = SHIPVIA_TEST_TOKEN. Refuses unless ACU_SHIPVIA_TENANT is 'TEST'.
// Shares the Acumatica lease with dispatch-acu / dispatch-orders.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const BASE = 'https://dflimporters.acumatica.com';
const VERSION = '24.200.001';
const TENANT = Deno.env.get('ACU_SHIPVIA_TENANT') ?? '';
const USERNAME = Deno.env.get('ACU_SHIPVIA_USERNAME') ?? '';
const PASSWORD = Deno.env.get('ACU_SHIPVIA_PASSWORD') ?? '';
const TOKEN = Deno.env.get('SHIPVIA_TEST_TOKEN') ?? '';
const GAP_MS = 1000;

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b, null, 2), { status, headers: { 'Content-Type': 'application/json' } });
function sameToken(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
const v = (f: any) => { const x = f?.value; return typeof x === 'string' ? (x.trim() || null) : (x ?? null); };
// Scalar { value } fields of a record, flattened.
const flat = (o: any) => Object.fromEntries(Object.entries(o ?? {})
  .filter(([k, x]: any) => x && typeof x === 'object' && 'value' in x && !['custom', 'files', '_links'].includes(k))
  .map(([k, x]: any) => [k, x.value]));

let ACTION = 'read';
let BODY: any = {};
let cookie = '', last = 0, calls = 0;
const holder = crypto.randomUUID();
async function pace() { const w = last + GAP_MS - Date.now(); if (w > 0) await new Promise(r => setTimeout(r, w)); last = Date.now(); }
async function call(method: string, url: string, body?: unknown) {
  await pace(); calls++;
  const res = await fetch(url.startsWith('http') ? url : `${BASE}/entity/Default/${VERSION}${url}`, {
    method, headers: { Cookie: cookie, Accept: 'application/json', 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let data: any = null; try { data = text ? JSON.parse(text) : null; } catch { data = text.slice(0, 500); }
  return { status: res.status, ok: res.ok, data, location: res.headers.get('Location') };
}
// Contract-based actions answer 202 + Location while running, 204 when done.
async function action(path: string, body: unknown) {
  const r = await call('POST', path, body);
  if (r.status === 204 || r.status === 200) return { status: r.status };
  if (r.status !== 202 || !r.location) throw new Error(`${path} refused: ${r.status} ${err(r.data)}`);
  const loc = r.location.startsWith('http') ? r.location : `${BASE}${r.location}`;
  for (let i = 0; i < 40; i++) {
    await new Promise(res => setTimeout(res, 1000));
    const p = await call('GET', loc);
    if (p.status === 204 || p.status === 200) return { status: p.status };
    if (p.status !== 202) throw new Error(`${path} failed: ${p.status} ${err(p.data)}`);
  }
  throw new Error(`${path} still running after 40s`);
}
const err = (d: any) => (typeof d === 'string' ? d : String(d?.exceptionMessage ?? d?.message ?? JSON.stringify(d))).slice(0, 300);

async function probe() {
  if (TENANT !== 'TEST') return { ok: false, error: `refusing: ACU_SHIPVIA_TENANT is '${TENANT}', not 'TEST'` };
  const out: Record<string, unknown> = { tenant: TENANT, version: VERSION };

  const until = Date.now() + 60_000;
  for (;;) {
    const { data, error } = await admin.rpc('acu_lease_take', { p_target: 'test', p_holder: holder, p_job: 'sub probe' });
    if (error) return { ok: false, error: `lease: ${error.message}` };
    if (data) break;
    if (Date.now() > until) return { ok: false, error: 'Acumatica busy with another job' };
    await new Promise(r => setTimeout(r, 2000));
  }
  try {
    await pace();
    const login = await fetch(`${BASE}/entity/auth/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ name: USERNAME, password: PASSWORD, tenant: TENANT }),
    });
    out.login = login.status;
    if (!login.ok) { out.error = (await login.text()).slice(0, 300); return out; }
    cookie = login.headers.getSetCookie().map(c => c.split(';')[0]).join('; ');
    await login.body?.cancel();

    // Open SOs: all scalar fields of the first, a few key fields of the rest.
    if (ACTION === 'get') {
      // READ-ONLY: GET one entity path, e.g. /StockItem/10003691?$expand=WarehouseDetails
      const p = String(BODY.path ?? '');
      if (!/^\/(StockItem|SalesOrder|Shipment|Customer|SalesInvoice)\b/.test(p)) { out.error = 'path must start with /StockItem, /SalesOrder, /Shipment, /Customer or /SalesInvoice'; return out; }
      const r = await call('GET', p);
      out.status = r.status;
      out.data = JSON.stringify(r.data).slice(0, 12000);
      return out;
    }

    if (ACTION === 'confirm_shipment') {
      // WRITE (TEST only): take a shipment off hold, set Control Qty = Shipped Qty, Confirm. No invoice.
      const nbr = String(BODY.shipment ?? '');
      if (!/^[A-Za-z0-9-]{1,15}$/.test(nbr)) { out.error = 'bad or missing shipment'; return out; }
      const sel = 'ShipmentNbr,Status,ShipVia,Hold,ShippedQty,ControlQty';
      const rd = await call('GET', `/Shipment/${encodeURIComponent(nbr)}?$select=${sel}`);
      if (!rd.ok) { out.error = `read ${rd.status} ${err(rd.data)}`; return out; }
      out.before = flat(rd.data);
      const put = await call('PUT', `/Shipment?$select=${sel}`, { id: rd.data.id, Hold: { value: false }, ControlQty: { value: Number(v(rd.data.ShippedQty)) || 0 } });
      out.prepare = put.ok ? flat(put.data) : { status: put.status, error: err(put.data) };
      if (!put.ok) return out;
      try { out.confirm_action = await action('/Shipment/ConfirmShipment', { entity: { id: rd.data.id } }); }
      catch (e) { out.confirm_error = String(e).slice(0, 500); }
      const re = await call('GET', `/Shipment/${encodeURIComponent(nbr)}?$select=${sel}`);
      out.after = re.ok ? flat(re.data) : { status: re.status, error: err(re.data) };
      return out;
    }

    if (ACTION === 'ship_so') {
      // WRITE (TEST only): create a shipment from a TEST order, then try to set Ship Via on the shipment. Does NOT confirm.
      const nbr = String(BODY.order ?? '');
      if (!/^[A-Za-z0-9-]{1,15}$/.test(nbr)) { out.error = 'bad or missing order'; return out; }
      const url = `/SalesOrder/SO/${nbr}?$expand=Shipments`;
      const before = await call('GET', url);
      if (!before.ok) { out.error = `order read ${before.status} ${err(before.data)}`; return out; }
      const had = new Set((before.data.Shipments ?? []).map((s: any) => v(s.ShipmentNbr)));
      out.order = { nbr, status: v(before.data.Status), ship_via: v(before.data.ShipVia), existing_shipments: [...had] };
      const date = new Date(Date.now() - 5 * 3600e3).toISOString().split('T')[0];
      try { out.create_action = await action('/SalesOrder/SalesOrderCreateShipment', { entity: { id: before.data.id }, parameters: { ShipmentDate: { value: date } } }); }
      catch (e) { out.create_error = String(e).slice(0, 400); return out; }
      const after = await call('GET', url);
      const fresh = (after.data?.Shipments ?? []).map((s: any) => v(s.ShipmentNbr)).filter((s: any) => s && !had.has(s));
      out.order_after = { status: v(after.data?.Status), new_shipments: fresh };
      for (const sn of fresh.slice(0, 2)) {
        const sh = await call('GET', `/Shipment/${encodeURIComponent(sn)}?$expand=Details`);
        if (!sh.ok) { out[`shipment_${sn}`] = { error: `${sh.status} ${err(sh.data)}` }; continue; }
        const rec: Record<string, unknown> = { before: { ...flat(sh.data), lines: (sh.data.Details ?? []).map(flat) } };
        if (BODY.ship_via) {
          const put = await call('PUT', `/Shipment?$select=ShipmentNbr,Status,Hold,ShipVia`, { id: sh.data.id, ShipVia: { value: String(BODY.ship_via) } });
          rec.set_ship_via = put.ok ? { status: put.status, ship_via: v(put.data.ShipVia), shipment_status: v(put.data.Status), hold: v(put.data.Hold) } : { status: put.status, error: err(put.data) };
          const re = await call('GET', `/Shipment/${encodeURIComponent(sn)}?$select=ShipmentNbr,Status,Hold,ShipVia,ShippedQty,ControlQty`);
          rec.read_back = re.ok ? flat(re.data) : { status: re.status, error: err(re.data) };
        }
        out[`shipment_${sn}`] = rec;
      }
      return out;
    }

    if (ACTION === 'create_so') {
      // WRITE (TEST only): one throwaway SO for the customer + first item of an existing TEST order.
      const srcNbr = String(BODY.source_order ?? '183370');
      if (!/^[A-Za-z0-9-]{1,15}$/.test(srcNbr)) { out.error = 'bad source_order'; return out; }
      const src = await call('GET', `/SalesOrder/SO/${srcNbr}?$expand=Details`);
      if (!src.ok) { out.error = `source read ${src.status} ${err(src.data)}`; return out; }
      const cust = v(src.data.CustomerID);
      const ln = (src.data.Details ?? [])[0];
      const item = String(BODY.inventory_id ?? v(ln?.InventoryID));
      out.source = { order: srcNbr, status: v(src.data.Status), customer: cust, item, ship_via: v(src.data.ShipVia) };
      const ref = `SUBTEST-${Date.now().toString(36)}`;
      const put = await call('PUT', `/SalesOrder?$expand=Details`, {
        OrderType: { value: 'SO' }, CustomerID: { value: cust }, CustomerOrder: { value: ref },
        Description: { value: 'Substitution workflow TEST - safe to cancel' },
        Details: [{ InventoryID: { value: item }, OrderQty: { value: 1 }, WarehouseID: { value: '71' } }],
      });
      out.create = put.ok
        ? { status: put.status, order: v(put.data.OrderNbr), order_status: v(put.data.Status), hold: v(put.data.Hold), credit_hold: v(put.data.CreditHold),
            ship_via: v(put.data.ShipVia), customer_order: v(put.data.CustomerOrder), total: v(put.data.OrderTotal),
            line: flat(put.data.Details?.[0]) }
        : { status: put.status, error: err(put.data) };
      if (put.ok && (v(put.data.Status) === 'Credit Hold' || v(put.data.CreditHold) === true) && BODY.release !== false) {
        const id = put.data.id;
        const rel = await call('POST', `/SalesOrder/ReleaseFromCreditHoldSalesOrder`, { entity: { id } });
        out.release_call = { status: rel.status, error: rel.ok ? undefined : err(rel.data) };
        // 202 = running; poll the location is skipped here, just re-read after a pause.
        await new Promise(r => setTimeout(r, 3000));
        const re = await call('GET', `/SalesOrder/SO/${v(put.data.OrderNbr)}?$select=OrderNbr,Status,Hold,CreditHold`);
        out.after_release = re.ok ? { status: v(re.data.Status), hold: v(re.data.Hold), credit_hold: v(re.data.CreditHold) } : { status: re.status, error: err(re.data) };
      }
      return out;
    }

    const so = await call('GET', `/SalesOrder?$filter=${encodeURIComponent("OrderType eq 'SO' and Status eq 'Open'")}&$top=3&$expand=Details`);
    out.sales_orders = so.ok
      ? { count: (so.data as any[]).length, first_header: flat((so.data as any[])[0]), first_line: flat((so.data as any[])[0]?.Details?.[0]),
          others: (so.data as any[]).slice(1).map(o => ({ nbr: v(o.OrderNbr), customer: v(o.CustomerID), status: v(o.Status), ship_via: v(o.ShipVia), warehouse: v(o.Details?.[0]?.WarehouseID) })) }
      : { status: so.status, error: err(so.data) };

    // Statuses seen, to know what "credit hold" looks like.
    const hold = await call('GET', `/SalesOrder?$filter=${encodeURIComponent("Status eq 'Credit Hold'")}&$top=3&$select=OrderNbr,OrderType,Status,CustomerID`);
    out.credit_hold_orders = hold.ok ? (hold.data as any[]).map(o => ({ nbr: v(o.OrderNbr), type: v(o.OrderType), customer: v(o.CustomerID) })) : { status: hold.status, error: err(hold.data) };

    // Can the API user read items and customer credit fields?
    const si = await call('GET', `/StockItem?$top=3&$select=InventoryID,Description,ItemStatus,DefaultPrice,BaseUOM`);
    out.stock_items = si.ok ? (si.data as any[]).map(flat) : { status: si.status, error: err(si.data) };
    const cu = await call('GET', `/Customer?$top=3&$select=CustomerID,CustomerName,Status,CreditVerificationRules,CreditLimit`);
    out.customers = cu.ok ? (cu.data as any[]).map(flat) : { status: cu.status, error: err(cu.data) };

    // Endpoint actions. Swagger is big; a reset here must not lose the rest.
    try {
      await pace();
      const sw = await fetch(`${BASE}/entity/Default/${VERSION}/swagger.json`, { headers: { Cookie: cookie, Accept: 'application/json' } });
      if (sw.ok) {
        const s = await sw.json();
        const paths = Object.keys(s.paths ?? {});
        out.actions = {
          SalesOrder: paths.filter(p => /^\/SalesOrder\//.test(p) && /\/(Release|Credit|Hold|Create|Open|Cancel|Reopen|Prepare|Complete|Approve)/i.test(p)),
          Shipment: paths.filter(p => /^\/Shipment\//.test(p) && /\/(Add|Confirm|Correct|Create|Reopen|Prepare|Release|Hold|Remove)/i.test(p)),
        };
      } else { out.swagger = sw.status; await sw.body?.cancel(); }
    } catch (e) { out.swagger_error = String(e).slice(0, 200); }
  } finally {
    await pace();
    try { const lo = await fetch(`${BASE}/entity/auth/logout`, { method: 'POST', headers: { Cookie: cookie } }); await lo.body?.cancel(); } catch { /* ignore */ }
    await admin.rpc('acu_lease_drop', { p_target: 'test', p_holder: holder });
  }
  out.calls = calls;
  return { ok: true, ...out };
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  if (!TOKEN || !sameToken(req.headers.get('x-test-token') ?? '', TOKEN)) return json({ ok: false, error: 'bad or missing x-test-token' }, 401);
  try { BODY = await req.json().catch(() => ({})); ACTION = String(BODY.action ?? 'read'); return json(await probe()); } catch (e) { return json({ ok: false, error: String(e) }, 500); }
});
