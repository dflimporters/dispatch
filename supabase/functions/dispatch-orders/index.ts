// Supabase Edge Function: dispatch-orders
// Sales Orders tab -> Acumatica: create shipments from sales orders.
//
// POST JSON { action, ... } with the signed-in user's access token as
// Authorization: Bearer <token>. verify_jwt is off because the token is checked
// here (auth.getUser) together with the caller's dispatch role, as in dispatch-acu.
//
//   status                                      -> which targets can be written. Coordinator.
//   list_test_orders                            -> read-only: Open / Back Order SOs in the Acumatica TEST
//                                                  tenant (the Sales Orders tab shows these in Test mode,
//                                                  because production order numbers don't exist there).
//   create_shipments { env, orders[], shipment_date }
//                                               -> coordinator only. For each order (up to 20): must be
//                                                  Open or Back Order, then runs Create Shipment with that
//                                                  shipment date and reads back the new shipment numbers.
//                                                  One row per order goes to dispatch_shipment_requests.
//   ship_invoice { env, orders[], shipment_date }
//                                               -> coordinator only, pickup / donation / promotion / office
//                                                  customers only. Create Shipment, then Confirm and Prepare
//                                                  Invoice, with no pick or check. Up to 3 orders a call.
//   probe_attachments { env, order }            -> read-only: lists the order's attachments and test-downloads them.
//   get_po { env, order }                       -> read-only: the order's attached files (customer PO) as base64, for printing.
//
// Targets: env 'test' = the TEST tenant on production (refuses unless ACU_SHIPVIA_TENANT is exactly
// TEST). env 'live' = production, refused until DISPATCH_LIVE_WRITEBACK = 'on' AND
// DISPATCH_LIVE_ORDERS = 'on' (switched on after a TEST run). Shares the Acumatica lease with
// dispatch-acu, so only one job at a time talks to a target, and calls are spaced to stay inside
// the API limits. Always signs out.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const admin = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

type Target = { key: 'test' | 'live'; label: string; base: string; version: string; username: string; password: string; tenant: string; gapMs: number; check(): string | null };
const TARGETS: Record<string, Target> = {
  test: {
    key: 'test', label: 'Acumatica TEST (2024R2)', base: 'https://dflimporters.acumatica.com', version: '24.200.001',
    username: Deno.env.get('ACU_SHIPVIA_USERNAME') ?? '', password: Deno.env.get('ACU_SHIPVIA_PASSWORD') ?? '',
    tenant: Deno.env.get('ACU_SHIPVIA_TENANT') ?? '', gapMs: 1000,
    check() { return this.tenant === 'TEST' ? null : `refusing: ACU_SHIPVIA_TENANT is '${this.tenant}', not 'TEST'`; },
  },
  live: {
    key: 'live', label: 'Acumatica (live)', base: 'https://dflimporters.acumatica.com', version: '24.200.001',
    username: Deno.env.get('ACU_LIVE_USERNAME') ?? Deno.env.get('ACU_SHIPVIA_USERNAME') ?? '',
    password: Deno.env.get('ACU_LIVE_PASSWORD') ?? Deno.env.get('ACU_SHIPVIA_PASSWORD') ?? '',
    tenant: Deno.env.get('ACU_LIVE_TENANT') ?? '', gapMs: 1000,
    check() {
      if (Deno.env.get('DISPATCH_LIVE_WRITEBACK') !== 'on' || !this.username || !this.tenant) return 'Live writeback isn\'t switched on yet. Test only for now.';
      return Deno.env.get('DISPATCH_LIVE_ORDERS') === 'on' ? null : 'Creating live shipments from the portal isn\'t switched on yet (after a TEST run).';
    },
  },
};

function cors(): Record<string, string> {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };
}
function v(field: any): any {
  const x = field?.value;
  return typeof x === 'string' ? (x.trim() || null) : (x ?? null);
}
function acuError(data: any): string {
  if (!data) return 'no detail';
  if (typeof data === 'string') return data.slice(0, 300);
  const inner = data.innerException ? ` | ${acuError(data.innerException)}` : '';
  return (String(data.exceptionMessage ?? data.message ?? JSON.stringify(data)).slice(0, 300) + inner).slice(0, 400);
}
const jmToday = () => new Date(Date.now() - 5 * 3600e3).toISOString().split('T')[0];

class Acu {
  cookie = '';
  private last = 0;
  private holder = crypto.randomUUID();
  private leased = false;
  constructor(private t: Target, private job: string) {}
  private get entity() { return `${this.t.base}/entity/Default/${this.t.version}`; }
  private async pace() {
    const wait = this.last + this.t.gapMs - Date.now();
    if (wait > 0) await new Promise(r => setTimeout(r, wait));
    this.last = Date.now();
  }
  async lease() {
    const until = Date.now() + 60_000;
    for (;;) {
      const { data, error } = await admin.rpc('acu_lease_take', { p_target: this.t.key, p_holder: this.holder, p_job: this.job });
      if (error) throw new Error(`lease: ${error.message}`);
      if (data) { this.leased = true; return; }
      if (this.leased) throw new Error('Lost the Acumatica lease to another run');
      if (Date.now() > until) throw new Error('Acumatica is busy with another job. Try again in a minute.');
      await new Promise(r => setTimeout(r, 2000));
    }
  }
  async login() {
    await this.lease();
    await this.pace();
    const res = await fetch(`${this.t.base}/entity/auth/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
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
      method, headers: { Cookie: this.cookie, Accept: 'application/json', 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let data: any = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = text.slice(0, 2000); }
    return { status: res.status, ok: res.ok, data, location: res.headers.get('Location') };
  }
  // Binary GET (attachments). Returns the bytes, not parsed JSON.
  async raw(url: string) {
    await this.pace();
    // A file's href is rooted at the site ("/entity/Default/.../files/<id>"), unlike the entity paths used elsewhere.
    const full = url.startsWith('http') ? url : url.startsWith('/entity/') ? `${this.t.base}${url}` : `${this.entity}${url}`;
    const res = await fetch(full, { headers: { Cookie: this.cookie, Accept: '*/*' } });
    return { status: res.status, ok: res.ok, type: res.headers.get('Content-Type') ?? '', disposition: res.headers.get('Content-Disposition') ?? '', bytes: new Uint8Array(await res.arrayBuffer()) };
  }
  // Contract-based actions answer 202 + Location while running, 204 when done.
  async action(path: string, body: unknown) {
    const r = await this.call('POST', path, body);
    if (r.status === 204 || r.status === 200) return;
    if (r.status !== 202 || !r.location) throw new Error(`${path} refused: ${r.status} ${acuError(r.data)}`);
    const loc = r.location.startsWith('http') ? r.location : `${this.t.base}${r.location}`;
    for (let i = 0; i < 60; i++) {
      await new Promise(res => setTimeout(res, 1000));
      const p = await this.call('GET', loc);
      if (p.status === 204 || p.status === 200) return;
      if (p.status !== 202) throw new Error(`${path} failed: ${p.status} ${acuError(p.data)}`);
    }
    throw new Error(`${path} still running after 60s`);
  }
}

const shipmentsOf = (o: any): string[] =>
  [...new Set((o?.Shipments ?? []).map((s: any) => v(s.ShipmentNbr)).filter(Boolean))] as string[];

// ------------------------------------------------------------------
async function listTestOrders() {
  const t = TARGETS.test; const why = t.check(); if (why) throw new Error(why);
  const acu = new Acu(t, 'orders list test');
  try {
    await acu.login();
    const filter = encodeURIComponent("OrderType eq 'SO' and (Status eq 'Open' or Status eq 'Back Order')");
    const r = await acu.call('GET', `/SalesOrder?$filter=${filter}&$select=OrderNbr,Status,Date,CustomerID,OrderedQty,OrderTotal,Details/InventoryID,Details/OrderQty&$expand=Details&$top=100`);
    if (!r.ok) throw new Error(`TEST orders read failed: ${r.status} ${acuError(r.data)}`);
    const raw: any[] = Array.isArray(r.data) ? r.data : [];

    // Names and zones come from the customers table (same customer IDs as production), volume per
    // case from the items on production orders (dispatch_item_volumes): TEST itself has neither.
    const custIds = [...new Set(raw.map(o => v(o.CustomerID)).filter(Boolean))] as string[];
    const items = [...new Set(raw.flatMap(o => (o.Details ?? []).map((d: any) => v(d.InventoryID))).filter(Boolean))] as string[];
    const cust = new Map<string, any>();
    for (let i = 0; i < custIds.length; i += 200) {
      const { data } = await admin.from('customers').select('customer_id, customer_name, shipping_zone').in('customer_id', custIds.slice(i, i + 200));
      (data ?? []).forEach(c => cust.set(c.customer_id, c));
    }
    const volume = new Map<string, number>();
    for (let i = 0; i < items.length; i += 300) {
      const { data } = await admin.rpc('dispatch_item_volumes', { p_ids: items.slice(i, i + 300) });
      (data ?? []).forEach((x: any) => volume.set(x.inventory_id, Number(x.volume) || 0));
    }
    return raw.map((o: any) => {
      const c = cust.get(v(o.CustomerID));
      return {
        order_nbr: v(o.OrderNbr), status: v(o.Status), order_date: v(o.Date)?.split('T')[0] ?? null, customer_id: v(o.CustomerID),
        customer_name: c?.customer_name ?? v(o.CustomerID), shipping_zone: c?.shipping_zone ?? null, order_total: Number(v(o.OrderTotal)) || 0,
        open_qty: Number(v(o.OrderedQty)) || 0,
        open_volume: (o.Details ?? []).reduce((t: number, d: any) => t + (Number(v(d.OrderQty)) || 0) * (volume.get(v(d.InventoryID)) ?? 0), 0),
        short_lines: 0, open_shipments: 0,
      };
    }).sort((a: any, b: any) => String(b.order_nbr).localeCompare(String(a.order_nbr)));
  } finally { await acu.logout(); }
}

// Read-only: what this tenant's Create Shipment action accepts, and the date fields on one order,
// so TEST and live can be compared when a shipment comes back with the wrong date.
async function probeCreateShipment(env: string, order?: string) {
  const t = TARGETS[env]; const why = t.check(); if (why) return { ok: false, error: why };
  const acu = new Acu(t, `orders probe ${env}`);
  try {
    await acu.login();
    await acu.lease();
    const sw = await fetch(`${t.base}/entity/Default/${t.version}/swagger.json`, { headers: { Cookie: acu.cookie, Accept: 'application/json' } });
    let params: Record<string, string[]> = {};
    if (sw.ok) {
      const s = await sw.json();
      const defs = s.definitions ?? s.components?.schemas ?? {};
      params = Object.fromEntries(Object.keys(defs).filter(k => /CreateShipment/i.test(k))
        .map(k => [k, Object.keys(defs[k]?.properties?.parameters?.properties ?? defs[k]?.properties ?? {})]));
    } else await sw.body?.cancel();
    let orderInfo: any = null;
    if (order && /^[A-Za-z0-9-]{1,15}$/.test(order)) {
      const r = await acu.call('GET', `/SalesOrder/SO/${encodeURIComponent(order)}?$expand=Details`);
      if (r.ok) {
        const flat = (x: any) => x && Object.fromEntries(Object.entries(x).filter(([k]) => /date|on$|ship|status|schedule/i.test(k) && k !== 'ShipVia')
          .map(([k, val]: any) => [k, val && typeof val === 'object' && 'value' in val ? val.value : val]));
        orderInfo = { header: flat(r.data), line1: flat(r.data?.Details?.[0]) };
      } else orderInfo = { error: `${r.status} ${acuError(r.data)}` };
    }
    return { ok: true, env, tenant: t.tenant, version: t.version, swagger: sw.status, createShipmentParams: params, order: orderInfo };
  } catch (e: any) {
    return { ok: false, error: String(e?.message ?? e) };
  } finally { await acu.logout(); }
}

// Read-only: do the order's attachments (the customer's PO file) come back through the API, and can they be downloaded?
// Lists the files on the order and fetches each (up to 5) only to report its size, type and first bytes; nothing is stored or written.
async function probeAttachments(env: string, order: string) {
  const t = TARGETS[env]; const why = t.check(); if (why) return { ok: false, error: why };
  if (!/^[A-Za-z0-9-]{1,15}$/.test(order)) return { ok: false, error: 'bad order number' };
  const acu = new Acu(t, `orders attachments ${env}`);
  try {
    await acu.login();
    await acu.lease();
    const r = await acu.call('GET', `/SalesOrder/SO/${encodeURIComponent(order)}?$expand=files`);
    if (!r.ok) return { ok: false, error: `read ${r.status} ${acuError(r.data)}` };
    const files: any[] = Array.isArray(r.data?.files) ? r.data.files : [];
    const out: any[] = [];
    for (const f of files.slice(0, 5)) {
      const info: any = { name: f.name ?? f.filename ?? null, id: f.id ?? null, href: f.href ?? null, keys: Object.keys(f) };
      if (f.href) {
        await acu.lease();
        const d = await acu.raw(f.href);
        info.download = { status: d.status, type: d.type, disposition: d.disposition, bytes: d.bytes.length,
          magic: new TextDecoder().decode(d.bytes.slice(0, 5)).replace(/[^\x20-\x7e]/g, '?') };
      }
      out.push(info);
    }
    return { ok: true, env, order, customer_order: v(r.data?.CustomerOrder), response_keys: Object.keys(r.data ?? {}), file_count: files.length, files: out };
  } catch (e: any) {
    return { ok: false, error: String(e?.message ?? e) };
  } finally { await acu.logout(); }
}

// The order's attached files (the customer's PO), for printing from the Sales Orders page. Read-only; nothing is stored.
// Returns up to 3 files as base64. An order with nothing attached comes back with an empty list.
const PO_MAX_FILES = 3, PO_MAX_BYTES = 8_000_000;
function b64(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
async function getPo(env: string, order: string) {
  const t = TARGETS[env]; const why = t.check(); if (why) return { ok: false, error: why };
  if (!/^[A-Za-z0-9-]{1,15}$/.test(order)) return { ok: false, error: 'bad order number' };
  const acu = new Acu(t, `orders po ${env}`);
  try {
    await acu.login();
    await acu.lease();
    const r = await acu.call('GET', `/SalesOrder/SO/${encodeURIComponent(order)}?$expand=files`);
    if (!r.ok) return { ok: false, error: `couldn't read order ${order}: ${r.status} ${acuError(r.data)}` };
    const listed: any[] = Array.isArray(r.data?.files) ? r.data.files : [];
    const files: any[] = [], skipped: string[] = [];
    for (const f of listed) {
      const name = String(f.filename ?? f.name ?? 'file').split(/[\\/]/).pop() || 'file';
      if (!f.href) continue;
      if (files.length >= PO_MAX_FILES) { skipped.push(`${name} (only the first ${PO_MAX_FILES} files are returned)`); continue; }
      await acu.lease();
      const d = await acu.raw(f.href);
      if (!d.ok) { skipped.push(`${name} (download failed: ${d.status})`); continue; }
      if (d.bytes.length > PO_MAX_BYTES) { skipped.push(`${name} (too large to print here)`); continue; }
      files.push({ name, type: d.type.split(';')[0] || 'application/octet-stream', bytes: d.bytes.length, data: b64(d.bytes) });
    }
    return { ok: true, order, customer_po: v(r.data?.CustomerOrder), attached: listed.length, files, skipped };
  } catch (e: any) {
    return { ok: false, error: String(e?.message ?? e) };
  } finally { await acu.logout(); }
}

// Returns a note for the request log, or '' when the date was already right.
async function fixShipmentDate(acu: Acu, nbr: string, date: string): Promise<string> {
  const url = `/Shipment/${encodeURIComponent(nbr)}?$select=ShipmentNbr,ShipmentDate`;
  const read = async () => {
    const r = await acu.call('GET', url);
    if (!r.ok) throw new Error(`read ${r.status} ${acuError(r.data)}`);
    return { id: r.data?.id as string, date: String(v(r.data?.ShipmentDate) ?? '').split('T')[0] };
  };
  const cur = await read();
  if (cur.date === date) return '';
  const put = await acu.call('PUT', `/Shipment?$select=ShipmentNbr,ShipmentDate`, { id: cur.id, ShipmentDate: { value: date } });
  if (!put.ok) return `${nbr}: Acumatica dated it ${cur.date || 'blank'} and refused the change to ${date} (${put.status} ${acuError(put.data)})`;
  const now = await read();
  return now.date === date ? `${nbr}: date set to ${date} (Acumatica had ${cur.date})` : `${nbr}: date still ${now.date} after trying to set ${date}`;
}

// Live Acumatica picks the lines to ship by today's date, not the ShipmentDate we send, and refuses when no line's
// Ship On has arrived. For lines due by `date` but not yet today, move Ship On to today so the shipment can be made.
// Returns what was moved so restoreShipOn can put it back; nothing is touched when no line needs it.
type Moved = { id: string; line: string; from: string };
async function moveShipOnToToday(acu: Acu, order: string, orderId: string, date: string): Promise<Moved[]> {
  const today = jmToday();
  const r = await acu.call('GET', `/SalesOrder/SO/${encodeURIComponent(order)}?$expand=Details`);
  if (!r.ok) throw new Error(`couldn't read lines of ${order}: ${r.status} ${acuError(r.data)}`);
  const moved: Moved[] = (r.data?.Details ?? [])
    .map((d: any) => ({ id: d.id as string, line: String(v(d.LineNbr) ?? '?'), from: String(v(d.ShipOn) ?? '').split('T')[0] }))
    .filter((d: Moved) => d.id && d.from > today && d.from <= date);
  if (!moved.length) return [];
  const put = await acu.call('PUT', `/SalesOrder?$expand=Details`, { id: orderId, Details: moved.map(m => ({ id: m.id, ShipOn: { value: today } })) });
  if (!put.ok) {
    // Part of the change may have gone through: put back whatever we can before giving up.
    await restoreShipOn(acu, orderId, moved);
    throw new Error(`couldn't move Ship On to today on ${order}: ${put.status} ${acuError(put.data)}`);
  }
  return moved;
}
// Returns '' when restored, else a warning for the request log and the results panel.
async function restoreShipOn(acu: Acu, orderId: string, moved: Moved[]): Promise<string> {
  if (!moved.length) return '';
  const put = await acu.call('PUT', `/SalesOrder?$expand=Details`, { id: orderId, Details: moved.map(m => ({ id: m.id, ShipOn: { value: m.from } })) });
  return put.ok ? '' : `WARNING: couldn't put Ship On back on line ${moved.map(m => `${m.line} (was ${m.from})`).join(', ')}: ${put.status} ${acuError(put.data)}`;
}

// ------------------------------------------------------------------
const BUDGET_MS = 110_000;
async function createShipments(env: string, orders: string[], date: string, actor: string) {
  const t = TARGETS[env]; const why = t.check(); if (why) return { ok: false, error: why };
  const started = Date.now();
  const results: any[] = [];
  const acu = new Acu(t, `orders create ${env}`);
  const record = (r: any) => admin.from('dispatch_shipment_requests').insert({
    env, order_nbr: r.order_nbr, shipment_date: date, state: r.state, shipment_nbrs: r.shipments ?? [], detail: r.detail ?? null, requested_by: actor,
  });
  try {
    await acu.login();
    for (const nbr of orders) {
      let r: any = { order_nbr: nbr, state: 'failed', shipments: [], detail: '' };
      try {
        if (Date.now() - started > BUDGET_MS) { r = { order_nbr: nbr, state: 'skipped', detail: 'Not attempted (ran out of time); select it again' }; results.push(r); continue; }
        const recent = await admin.from('dispatch_shipment_requests').select('id').eq('env', env).eq('order_nbr', nbr)
          .in('state', ['created']).gt('requested_at', new Date(Date.now() - 120_000).toISOString()).limit(1);
        if (recent.data?.length) { r = { order_nbr: nbr, state: 'skipped', detail: 'Shipment was just created for this order' }; results.push(r); continue; }
        await acu.lease();
        // No $select: with one, Acumatica drops the expanded Shipments, which read back as "no new shipment".
        const url = `/SalesOrder/SO/${encodeURIComponent(nbr)}?$expand=Shipments`;
        const before = await acu.call('GET', url);
        if (!before.ok) throw new Error(`couldn't read order ${nbr}: ${before.status} ${acuError(before.data)}`);
        const status = v(before.data?.Status);
        if (!['Open', 'Back Order'].includes(status)) {
          r = { order_nbr: nbr, state: 'refused', detail: `Order is ${status} in Acumatica, not Open or Back Order` };
        } else {
          const had = new Set(shipmentsOf(before.data));
          // Live Acumatica ignores this date whatever is sent (tried a full date-time and the warehouse too),
          // hence fixShipmentDate below; the parameters are logged with each request.
          const parameters: Record<string, unknown> = { ShipmentDate: { value: date } };
          const create = () => acu.action('/SalesOrder/SalesOrderCreateShipment', { entity: { id: before.data.id }, parameters });
          let moved: Moved[] = [];
          let restoreWarn = '';
          let createErr: any = null;
          try {
            try { await create(); }
            catch (e: any) {
              if (!/does not contain any items planned for shipment/i.test(String(e?.message ?? e))) throw e;
              moved = await moveShipOnToToday(acu, nbr, before.data.id, date);
              if (!moved.length) throw e;
              await create();
            }
          } catch (e: any) { createErr = e; }
          // Always put the dates back, whether or not the shipment was made.
          if (moved.length) restoreWarn = await restoreShipOn(acu, before.data.id, moved);
          if (createErr) throw new Error(`${String(createErr?.message ?? createErr)}${restoreWarn ? ` ${restoreWarn}` : ''}`);
          const after = await acu.call('GET', url);
          if (!after.ok) throw new Error(`created, but couldn't read ${nbr} back: ${after.status} ${acuError(after.data)}`);
          const fresh = shipmentsOf(after.data).filter(s => !had.has(s));
          const nowStatus = v(after.data?.Status);
          // Live Acumatica has come back with today's date whatever the action was given, so read each new
          // shipment back and set the date ourselves if it differs. A failure here is reported, never fatal:
          // the shipment exists either way.
          const dateNotes: string[] = [];
          for (const sn of fresh) {
            try { dateNotes.push(await fixShipmentDate(acu, sn, date)); } catch (e: any) { dateNotes.push(`${sn}: couldn't confirm the date (${String(e?.message ?? e).slice(0, 120)})`); }
          }
          const shipOnNote = moved.length ? (restoreWarn || `Ship On moved to today and back on line ${moved.map(m => m.line).join(', ')}`) : '';
          const dateNote = [...dateNotes, shipOnNote].filter(Boolean).join('; ');
          // Production orders are listed from our synced sales_orders table. Write the status Acumatica
          // just reported so the order leaves the list now, not at the next sync (which writes the same value).
          if (env === 'live' && nowStatus && nowStatus !== status) {
            const upd = await admin.from('sales_orders').update({ status: nowStatus }).eq('order_nbr', nbr).eq('order_type', 'SO');
            if (upd.error) console.error('sales_orders status update', nbr, upd.error.message);
          }
          r = fresh.length
            ? { order_nbr: nbr, state: 'created', shipments: fresh, detail: `Order is ${nowStatus}${dateNote ? `. ${dateNote}` : ''} [sent ${Object.entries(parameters).map(([k, x]) => `${k}=${(x as any).value}`).join(', ')}]` }
            : nowStatus !== status
              ? { order_nbr: nbr, state: 'created', detail: `Order moved to ${nowStatus}; the shipment number wasn't returned (see the Coordinator page after the next sync)` }
              : { order_nbr: nbr, state: 'none', detail: 'Acumatica made no shipment (nothing available to ship?)' };
        }
      } catch (e: any) { r = { order_nbr: nbr, state: 'failed', detail: String(e?.message ?? e).slice(0, 700) }; }
      results.push(r);
      await record(r);
    }
  } catch (e: any) {
    return { ok: false, error: String(e?.message ?? e), results };
  } finally { await acu.logout(); }
  return { ok: true, results };
}

// ------------------------------------------------------------------
// ship_invoice: pickup / donation / promotion / DFL Office orders go straight to an invoice, with no picking or
// checking. Per order: Create Shipment (as above), then per new shipment take it off hold, set Control Qty to the
// shipped total, Confirm, and Prepare Invoice. The invoice is left unreleased (Accounts releases it).
// A step that fails after the shipment exists is reported as state 'created' with what is left to do by hand.
const EDITABLE = ['Open', 'On Hold'];
async function specialCustomers(orders: string[]): Promise<Map<string, string>> {
  const { data: so } = await admin.from('sales_orders').select('order_nbr, customer').eq('order_type', 'SO').in('order_nbr', orders);
  const custOf = new Map<string, string>((so ?? []).map((r: any) => [r.order_nbr, r.customer]));
  const ids = [...new Set([...custOf.values()].filter(Boolean))];
  const kind = new Map<string, string>();
  if (ids.length) {
    const { data: ov } = await admin.from('customer_kind_overrides').select('customer_id, kind').in('customer_id', ids);
    (ov ?? []).forEach((o: any) => kind.set(o.customer_id, o.kind));
    const { data: cs } = await admin.from('customers').select('customer_id, customer_class').in('customer_id', ids);
    (cs ?? []).forEach((c: any) => { if (!kind.has(c.customer_id) && String(c.customer_class ?? '').toUpperCase() === 'PROMOTION') kind.set(c.customer_id, 'promotion'); });
  }
  return new Map(orders.map(o => [o, kind.get(custOf.get(o) ?? '') ?? '']));
}

async function confirmAndInvoice(acu: Acu, env: string, nbr: string, actor: string): Promise<string> {
  const mirror = env === 'test' ? 'shipments_test' : 'shipments';
  const sel = 'ShipmentNbr,Status,ShipVia,Hold,ShippedQty,ControlQty';
  const read = async () => {
    await acu.lease();
    const r = await acu.call('GET', `/Shipment/${encodeURIComponent(nbr)}?$select=${sel}`);
    if (!r.ok) throw new Error(`couldn't read ${nbr}: ${r.status} ${acuError(r.data)}`);
    return { id: r.data?.id as string, status: v(r.data?.Status) as string, via: v(r.data?.ShipVia), qty: Number(v(r.data?.ShippedQty)) || 0 };
  };
  let sh = await read();
  if (!['Confirmed', 'Completed', 'Invoiced'].includes(sh.status)) {
    if (!EDITABLE.includes(sh.status)) throw new Error(`shipment ${nbr} is ${sh.status}, not Open`);
    if (!sh.via) throw new Error(`shipment ${nbr} has no Ship Via (set one in Acumatica, then confirm it there)`);
    if (sh.qty <= 0) throw new Error(`shipment ${nbr} has nothing to ship (shipped qty 0)`);
    const ctl = await acu.call('PUT', `/Shipment?$select=${sel}`, { id: sh.id, Hold: { value: false }, ControlQty: { value: sh.qty } });
    if (!ctl.ok) throw new Error(`Control Qty refused on ${nbr}: ${ctl.status} ${acuError(ctl.data)}`);
    await acu.lease();
    await acu.action('/Shipment/ConfirmShipment', { entity: { id: sh.id } });
    sh = await read();
    if (sh.status !== 'Confirmed') throw new Error(`shipment ${nbr} is ${sh.status} after Confirm, not Confirmed`);
  }
  await admin.from(mirror).update({ status: sh.status }).eq('shipment_nbr', nbr);
  if (sh.status === 'Confirmed') {
    await acu.lease();
    await acu.action('/Shipment/PrepareInvoice', { entity: { id: sh.id } });
    sh = await read();
    if (sh.status === 'Confirmed') throw new Error(`Prepare Invoice ran on ${nbr}, but it is still Confirmed`);
    await admin.from(mirror).update({ status: sh.status }).eq('shipment_nbr', nbr);
  }
  const now = new Date().toISOString();
  await admin.from('shipment_invoicing').upsert({ env, shipment_nbr: nbr, state: 'done', detail: 'Shipped and invoiced from Sales Orders', requested_by: actor, requested_at: now, finished_at: now, updated_at: now }, { onConflict: 'env,shipment_nbr' });
  return sh.status;
}

async function shipInvoice(env: string, orders: string[], date: string, actor: string) {
  const t = TARGETS[env]; const why = t.check(); if (why) return { ok: false, error: why };
  if (env === 'live' && (Deno.env.get('DISPATCH_LIVE_INVOICE') !== 'on' || Deno.env.get('DISPATCH_LIVE_CHECKER') !== 'on'))
    return { ok: false, error: 'Confirming and invoicing live shipments isn\'t switched on yet (DISPATCH_LIVE_INVOICE and DISPATCH_LIVE_CHECKER).' };
  const kinds = await specialCustomers(orders);
  const results: any[] = [];
  for (const nbr of orders) {
    if (!kinds.get(nbr)) { results.push({ order_nbr: nbr, state: 'refused', detail: 'Only pickup, donation, promotion and DFL Office orders can skip picking and checking' }); continue; }
    const made = await createShipments(env, [nbr], date, actor);
    const r = ((made as any).results ?? [])[0] ?? { order_nbr: nbr, state: 'failed', detail: (made as any).error ?? 'No result' };
    if (r.state !== 'created' || !(r.shipments ?? []).length) { results.push(r); continue; }
    const acu = new Acu(t, `orders invoice ${env}`);
    const done: string[] = [], notes: string[] = [];
    try {
      await acu.login();
      for (const sn of r.shipments) {
        try { await confirmAndInvoice(acu, env, sn, actor); done.push(sn); }
        catch (e: any) { notes.push(String(e?.message ?? e).slice(0, 300)); }
      }
    } catch (e: any) { notes.push(String(e?.message ?? e).slice(0, 300)); }
    finally { await acu.logout(); }
    const all = done.length === r.shipments.length;
    results.push({ ...r, state: all ? 'invoiced' : 'created',
      detail: all ? `Confirmed and invoice prepared (${kinds.get(nbr)})${r.detail ? `. ${r.detail}` : ''}` : `Shipment made but not fully invoiced: ${notes.join('; ')}. Finish it in Acumatica or on the Invoicing page.` });
  }
  return { ok: true, results };
}

// ------------------------------------------------------------------
Deno.serve(async (req) => {
  const headers = { ...cors(), 'Content-Type': 'application/json' };
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors() });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);

  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
  let p: any = {};
  try { p = await req.json(); } catch { /* empty */ }

  const { data: u, error: uErr } = token ? await admin.auth.getUser(token) : { data: null, error: true } as any;
  if (uErr || !u?.user) return json({ ok: false, error: 'Sign in first' }, 401);
  const { data: roleRows } = await admin.from('dispatch_roles').select('role').eq('user_id', u.user.id);
  if (!(roleRows ?? []).some(r => r.role === 'batcher')) return json({ ok: false, error: 'Only the coordinator can use the Sales Orders tab' }, 403);
  const { data: prof } = await admin.from('profiles').select('full_name').eq('id', u.user.id).maybeSingle();
  const actor = prof?.full_name ?? u.user.email ?? 'unknown';

  try {
    switch (p.action) {
      case 'status':
        return json({ ok: true, test: TARGETS.test.check() === null, test_why: TARGETS.test.check(), live: TARGETS.live.check() === null, live_why: TARGETS.live.check() });
      case 'list_test_orders':
        return json({ ok: true, orders: await listTestOrders() });
      case 'probe_create_shipment':
        return json(await probeCreateShipment(p.env === 'live' ? 'live' : 'test', p.order ? String(p.order) : undefined));
      case 'probe_attachments':
        return json(await probeAttachments(p.env === 'live' ? 'live' : 'test', String(p.order ?? '')));
      case 'get_po':
        return json(await getPo(p.env === 'live' ? 'live' : 'test', String(p.order ?? '')));
      case 'create_shipments': {
        const env = p.env === 'live' ? 'live' : 'test';
        const date = String(p.shipment_date ?? '');
        if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || date < jmToday()) return json({ ok: false, error: 'Shipment date must be today or later' }, 400);
        const orders = [...new Set((Array.isArray(p.orders) ? p.orders : []).map((o: any) => String(o).trim()).filter((o: string) => /^[A-Za-z0-9-]{1,15}$/.test(o)))] as string[];
        if (!orders.length || orders.length > 20) return json({ ok: false, error: 'Select 1 to 20 orders' }, 400);
        return json(await createShipments(env, orders, date, actor));
      }
      case 'ship_invoice': {
        const env = p.env === 'live' ? 'live' : 'test';
        const date = String(p.shipment_date ?? '');
        if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || date < jmToday()) return json({ ok: false, error: 'Shipment date must be today or later' }, 400);
        const orders = [...new Set((Array.isArray(p.orders) ? p.orders : []).map((o: any) => String(o).trim()).filter((o: string) => /^[A-Za-z0-9-]{1,15}$/.test(o)))] as string[];
        if (!orders.length || orders.length > 3) return json({ ok: false, error: 'Select 1 to 3 orders per request' }, 400);
        return json(await shipInvoice(env, orders, date, actor));
      }
      default:
        return json({ ok: false, error: `unknown action ${p.action}` }, 400);
    }
  } catch (e: any) {
    console.error('dispatch-orders', p.action, e);
    return json({ ok: false, error: String(e?.message ?? e) }, 500);
  }
});
