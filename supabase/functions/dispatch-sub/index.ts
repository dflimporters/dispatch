// Supabase Edge Function: dispatch-sub
// Item substitution through the Acumatica API (Invoicing page).
//
// The checker flags a short line (check_items.sub_needed). The invoicer picks the replacement item and a quantity
// for each customer on the flag. For each customer this makes a separate SO (an SO belongs to one customer),
// then, step by step, with the last finished step recorded on the substitutions row so a failure resumes where it stopped:
//
//   so        -> PUT SalesOrder (Customer Order Nbr = the row's ref, looked up first so a retry never makes a second SO)
//   released  -> release from Credit Hold if the new SO landed there
//   shipment  -> Create Shipment (needs the item available in the warehouse)
//   shipvia   -> set the load's Ship Via on the shipment (the SO does not inherit one)
//   confirmed -> take off hold, Control Qty = Shipped Qty, Confirm Shipment
//   joined    -> _substitution_join_load: put the shipment and its lines on the same load, mark the load sheet stale
//
// POST JSON { action, ... } with the signed-in user's access token as Authorization: Bearer <token>. verify_jwt is
// off because the token and the caller's dispatch role are checked here, as in dispatch-orders.
//
//   status                      -> which targets can be written.
//   search_items { env, q }     -> read-only: active stock items whose name or item number matches the text.
//   run { env, load_id, source_inventory_id, sub_inventory_id, lines: [{ shipment, qty }] }
//                               -> supervisor / invoicer / manager. Validates the open flag and each customer line,
//                                  records one substitutions row per line, then runs the steps. Run it again with the
//                                  same body to resume a failed or unfinished row. Done rows are left alone.
//
// Targets: env 'test' = the TEST tenant (refuses unless ACU_SHIPVIA_TENANT is exactly TEST). env 'live' stays refused
// until DISPATCH_LIVE_WRITEBACK = 'on' AND DISPATCH_LIVE_SUBSTITUTION = 'on' (after a TEST pilot).
// Shares the Acumatica lease with dispatch-acu / dispatch-orders. Always signs out.

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
      return Deno.env.get('DISPATCH_LIVE_SUBSTITUTION') === 'on' ? null : 'Substitutions on live aren\'t switched on yet (after a TEST pilot).';
    },
  },
};

const BUDGET_MS = 100_000;   // leave the rest queued rather than hit the function's time limit
const ROLES = ['supervisor', 'invoicer', 'manager', 'admin'];

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
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

class Acu {
  cookie = '';
  private last = 0;
  private holder = crypto.randomUUID();
  private leased = false;
  constructor(private t: Target, private job: string) {}
  private get entity() { return `${this.t.base}/entity/Default/${this.t.version}`; }
  private async pace() {
    const wait = this.last + this.t.gapMs - Date.now();
    if (wait > 0) await sleep(wait);
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
      await sleep(2000);
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
  // Contract-based actions answer 202 + Location while running, 204 when done.
  async action(path: string, body: unknown) {
    const r = await this.call('POST', path, body);
    if (r.status === 204 || r.status === 200) return;
    if (r.status !== 202 || !r.location) throw new Error(`${path} refused: ${r.status} ${acuError(r.data)}`);
    const loc = r.location.startsWith('http') ? r.location : `${this.t.base}${r.location}`;
    for (let i = 0; i < 60; i++) {
      await sleep(1000);
      const p = await this.call('GET', loc);
      if (p.status === 204 || p.status === 200) return;
      if (p.status !== 202) throw new Error(`${path} failed: ${p.status} ${acuError(p.data)}`);
    }
    throw new Error(`${path} still running after 60s`);
  }
}

// ------------------------------------------------------------------
// search_items: read-only
async function searchItems(env: string, q: string) {
  const t = TARGETS[env]; const why = t.check(); if (why) return { ok: false, error: why };
  const text = q.replace(/[^A-Za-z0-9 .\-/]/g, '').trim().slice(0, 40);
  if (text.length < 2) return { ok: true, items: [] };
  const acu = new Acu(t, `sub search ${env}`);
  try {
    await acu.login();
    const esc = text.replace(/'/g, "''");
    const filter = encodeURIComponent(`ItemStatus eq 'Active' and (substringof('${esc}',Description) or startswith(InventoryID,'${esc}'))`);
    const r = await acu.call('GET', `/StockItem?$filter=${filter}&$select=InventoryID,Description,SalesUOM,BaseUOM&$top=15`);
    if (!r.ok) return { ok: false, error: `Item search failed: ${r.status} ${acuError(r.data)}` };
    const items = (Array.isArray(r.data) ? r.data : []).map((i: any) => (
      { inventory_id: v(i.InventoryID), description: v(i.Description), uom: v(i.SalesUOM) ?? v(i.BaseUOM) }));
    return { ok: true, items };
  } catch (e: any) {
    return { ok: false, error: String(e?.message ?? e) };
  } finally { await acu.logout(); }
}

// ------------------------------------------------------------------
// The steps for one substitutions row. Throws with a plain message when a step fails; the caller records it.
const STEPS = ['none', 'so', 'released', 'shipment', 'shipvia', 'confirmed', 'joined'];
const at = (row: any, step: string) => STEPS.indexOf(row.step) >= STEPS.indexOf(step);

async function setRow(id: number, patch: Record<string, unknown>) {
  const { error } = await admin.from('substitutions').update({ ...patch, updated_at: new Date().toISOString() }).eq('id', id);
  if (error) throw new Error(`couldn't save progress: ${error.message}`);
}

async function runOne(acu: Acu, env: string, row: any, load: any, warehouse: string) {
  await setRow(row.id, { state: 'running', error: null });

  // 1. The SO. Look it up by its Customer Order Nbr first so a retry never makes a second one.
  if (!at(row, 'so')) {
    await acu.lease();
    const f = encodeURIComponent(`OrderType eq 'SO' and CustomerOrder eq '${row.ref}'`);
    const found = await acu.call('GET', `/SalesOrder?$filter=${f}&$select=OrderNbr,Status,CustomerID`);
    if (!found.ok) throw new Error(`couldn't look for an existing SO: ${found.status} ${acuError(found.data)}`);
    let nbr = v((found.data as any[])?.[0]?.OrderNbr) as string | null;
    let price: number | null = null;
    if (!nbr) {
      await acu.lease();
      const put = await acu.call('PUT', `/SalesOrder?$expand=Details`, {
        OrderType: { value: 'SO' }, CustomerID: { value: row.customer_id }, CustomerOrder: { value: row.ref },
        Description: { value: `Substitute for ${row.source_inventory_id} on ${load.load_nbr} (order ${row.orig_order_nbr ?? '?'})` },
        Details: [{ InventoryID: { value: row.sub_inventory_id }, OrderQty: { value: Number(row.qty) }, WarehouseID: { value: warehouse }, ShippingRule: { value: 'Cancel Remainder' } }],
      });
      if (!put.ok) throw new Error(`Acumatica refused the new SO: ${put.status} ${acuError(put.data)}`);
      nbr = v(put.data?.OrderNbr);
      price = Number(v(put.data?.Details?.[0]?.UnitPrice)) || null;
    }
    if (!nbr) throw new Error('Acumatica made the SO but gave no order number');
    row = { ...row, new_order_nbr: nbr, step: 'so' };
    await setRow(row.id, { step: 'so', new_order_nbr: nbr, unit_price: price });
  }

  const soUrl = `/SalesOrder/SO/${encodeURIComponent(row.new_order_nbr)}?$expand=Shipments`;

  // 2. Credit hold. A new SO for a customer over their limit lands on Credit Hold.
  if (!at(row, 'released')) {
    await acu.lease();
    let so = await acu.call('GET', soUrl);
    if (!so.ok) throw new Error(`couldn't read SO ${row.new_order_nbr}: ${so.status} ${acuError(so.data)}`);
    if (v(so.data.Status) === 'Credit Hold' || v(so.data.CreditHold) === true) {
      await acu.action('/SalesOrder/ReleaseFromCreditHoldSalesOrder', { entity: { id: so.data.id } });
      for (let i = 0; i < 5; i++) {
        await sleep(1500);
        so = await acu.call('GET', soUrl);
        if (so.ok && v(so.data.Status) !== 'Credit Hold') break;
      }
    }
    const st = so.ok ? v(so.data.Status) : null;
    if (st === 'Credit Hold') throw new Error(`SO ${row.new_order_nbr} is still on Credit Hold after the release. Release it in Acumatica, then run this again.`);
    if (st !== 'Open') throw new Error(`SO ${row.new_order_nbr} is ${st ?? 'unreadable'}, not Open. Sort it in Acumatica, then run this again.`);
    row = { ...row, step: 'released' };
    await setRow(row.id, { step: 'released' });
  }

  // 3. The shipment.
  if (!at(row, 'shipment')) {
    await acu.lease();
    let so = await acu.call('GET', soUrl);
    if (!so.ok) throw new Error(`couldn't read SO ${row.new_order_nbr}: ${so.status} ${acuError(so.data)}`);
    let nbrs = [...new Set((so.data.Shipments ?? []).map((s: any) => v(s.ShipmentNbr)).filter(Boolean))] as string[];
    if (!nbrs.length) {
      try {
        await acu.action('/SalesOrder/SalesOrderCreateShipment', { entity: { id: so.data.id }, parameters: { ShipmentDate: { value: jmToday() } } });
      } catch (e: any) {
        const m = String(e?.message ?? e);
        if (/cannot be shipped in full/i.test(m)) throw new Error(`Not enough ${row.sub_inventory_id} available in warehouse ${warehouse} to ship ${row.qty} (other orders may be holding the stock). SO ${row.new_order_nbr} is made and released; pick a different item or qty and run again, or cancel that SO in Acumatica.`);
        throw e;
      }
      await acu.lease();
      so = await acu.call('GET', soUrl);
      nbrs = [...new Set((so.data?.Shipments ?? []).map((s: any) => v(s.ShipmentNbr)).filter(Boolean))] as string[];
    }
    if (nbrs.length !== 1) throw new Error(nbrs.length ? `SO ${row.new_order_nbr} has ${nbrs.length} shipments (${nbrs.join(', ')}); expected one. Sort it in Acumatica.` : `Acumatica made no shipment for SO ${row.new_order_nbr}`);
    row = { ...row, step: 'shipment', new_shipment_nbr: nbrs[0] };
    await setRow(row.id, { step: 'shipment', new_shipment_nbr: nbrs[0] });
  }

  const shSel = 'ShipmentNbr,Status,ShipVia,Hold,ShippedQty,ControlQty';
  const shUrl = `/Shipment/${encodeURIComponent(row.new_shipment_nbr)}`;

  // 4. Ship Via on the shipment (the SO doesn't inherit one).
  if (!at(row, 'shipvia')) {
    if (!load.ship_via) throw new Error(`${load.load_nbr} has no Ship Via to put on the shipment`);
    await acu.lease();
    const rd = await acu.call('GET', `${shUrl}?$select=${shSel}`);
    if (!rd.ok) throw new Error(`couldn't read shipment ${row.new_shipment_nbr}: ${rd.status} ${acuError(rd.data)}`);
    if (v(rd.data.ShipVia) !== load.ship_via) {
      const put = await acu.call('PUT', `/Shipment?$select=${shSel}`, { id: rd.data.id, ShipVia: { value: load.ship_via } });
      if (!put.ok) throw new Error(`Acumatica refused Ship Via ${load.ship_via} on shipment ${row.new_shipment_nbr}: ${put.status} ${acuError(put.data)}`);
    }
    row = { ...row, step: 'shipvia' };
    await setRow(row.id, { step: 'shipvia' });
  }

  // 5. Confirm.
  if (!at(row, 'confirmed')) {
    await acu.lease();
    let rd = await acu.call('GET', `${shUrl}?$select=${shSel}`);
    if (!rd.ok) throw new Error(`couldn't read shipment ${row.new_shipment_nbr}: ${rd.status} ${acuError(rd.data)}`);
    let st = v(rd.data.Status);
    if (!['Confirmed', 'Completed', 'Invoiced'].includes(st)) {
      if (!['On Hold', 'Open'].includes(st)) throw new Error(`shipment ${row.new_shipment_nbr} is ${st}, not Open`);
      const qty = Number(v(rd.data.ShippedQty)) || 0;
      if (qty <= 0) throw new Error(`shipment ${row.new_shipment_nbr} has nothing to ship (shipped qty 0)`);
      const ctl = await acu.call('PUT', `/Shipment?$select=${shSel}`, { id: rd.data.id, Hold: { value: false }, ControlQty: { value: qty } });
      if (!ctl.ok) throw new Error(`Control Qty refused on shipment ${row.new_shipment_nbr}: ${ctl.status} ${acuError(ctl.data)}`);
      await acu.lease();
      await acu.action('/Shipment/ConfirmShipment', { entity: { id: rd.data.id } });
      rd = await acu.call('GET', `${shUrl}?$select=${shSel}`);
      st = rd.ok ? v(rd.data.Status) : null;
      if (st !== 'Confirmed') throw new Error(`shipment ${row.new_shipment_nbr} is ${st ?? 'unreadable'} after Confirm, not Confirmed`);
    }
    row = { ...row, step: 'confirmed' };
    await setRow(row.id, { step: 'confirmed' });
  }

  // 6. Join the load: read the shipment back with its lines and let the database put it on the load.
  await acu.lease();
  const sh = await acu.call('GET', `${shUrl}?$expand=Details`);
  if (!sh.ok) throw new Error(`couldn't read shipment ${row.new_shipment_nbr} to join it to the load: ${sh.status} ${acuError(sh.data)}`);
  // Each line's price comes from the SO line it ships (the SO was priced by Acumatica at the customer's default price).
  await acu.lease();
  const od = await acu.call('GET', `/SalesOrder/SO/${encodeURIComponent(row.new_order_nbr)}?$expand=Details`);
  const price = new Map<string, number>();
  if (od.ok) for (const d of od.data?.Details ?? []) price.set(String(v(d.LineNbr)), Number(v(d.UnitPrice)) || 0);
  const lines = (sh.data.Details ?? []).map((d: any) => {
    const q = Number(v(d.ShippedQty)) || 0, unit = price.get(String(v(d.OrderLineNbr))) ?? 0;
    return { line_nbr: v(d.LineNbr), inventory_id: v(d.InventoryID), description: v(d.Description), uom: v(d.UOM),
             ordered_qty: Number(v(d.OrderedQty)) || 0, shipped_qty: q, order_nbr: v(d.OrderNbr), order_line_nbr: v(d.OrderLineNbr),
             location_id: v(d.LocationID), unit_price: unit || null, line_value: unit ? Math.round(unit * q * 100) / 100 : null };
  });
  // The SO line is Cancel Remainder, so if less than the asked-for quantity was available Acumatica ships what it has and
  // cancels the rest. Say so instead of reporting the full quantity.
  const shipped = lines.reduce((t: number, l: any) => t + l.shipped_qty, 0);
  if (shipped <= 0) throw new Error(`shipment ${row.new_shipment_nbr} has nothing on it (shipped qty 0)`);
  if (shipped < Number(row.qty)) {
    const note = `Asked for ${row.qty} but only ${shipped} of ${row.sub_inventory_id} could ship; the rest was cancelled on SO ${row.new_order_nbr}.`;
    await setRow(row.id, { qty: shipped, note, unit_price: lines[0]?.unit_price ?? null });
    row = { ...row, qty: shipped };
  } else {
    await setRow(row.id, { unit_price: lines[0]?.unit_price ?? null });
  }
  const header = {
    shipment_nbr: row.new_shipment_nbr, status: v(sh.data.Status), shipment_date: String(v(sh.data.ShipmentDate) ?? '').split('T')[0] || jmToday(),
    customer_id: row.customer_id, customer_name: row.customer_name, warehouse_id: v(sh.data.WarehouseID) ?? warehouse,
    shipping_zone: v(sh.data.ShippingZoneID), ship_via: v(sh.data.ShipVia), shipped_qty: Number(v(sh.data.ShippedQty)) || 0,
    order_nbr: row.new_order_nbr, ordered_qty: lines.reduce((t: number, l: any) => t + l.ordered_qty, 0),
    shipment_value: lines.reduce((t: number, l: any) => t + (l.line_value ?? 0), 0),
  };
  const j = await admin.rpc('_substitution_join_load', { p_id: row.id, p_header: header, p_lines: lines });
  if (j.error) throw new Error(`couldn't join the load: ${j.error.message}`);
}

// ------------------------------------------------------------------
async function run(env: string, p: any, actor: { id: string; name: string }) {
  const t = TARGETS[env]; const why = t.check(); if (why) return { ok: false, error: why };
  const loadId = Number(p.load_id), src = String(p.source_inventory_id ?? ''), sub = String(p.sub_inventory_id ?? '').trim();
  if (!Number.isInteger(loadId) || !src || !/^[A-Za-z0-9 ._-]{1,30}$/.test(sub)) return { ok: false, error: 'Missing load, flagged item or substitute item' };
  if (sub === src) return { ok: false, error: 'The substitute is the same item that was short' };
  const want = new Map<string, number>();
  for (const x of Array.isArray(p.lines) ? p.lines : []) {
    const q = Number(x?.qty), s = String(x?.shipment ?? '');
    if (s && Number.isFinite(q) && q > 0) want.set(s, q);
  }
  if (!want.size) return { ok: false, error: 'Enter a quantity for at least one customer' };

  const { data: load } = await admin.from('loads').select('id, env, load_nbr, ship_via, checker_done_at').eq('id', loadId).maybeSingle();
  if (!load) return { ok: false, error: 'Load not found' };
  if (load.env !== env) return { ok: false, error: `${load.load_nbr} is a ${load.env} load, not ${env}` };
  const { data: flag } = await admin.from('check_items').select('sub_needed, sub_resolved_at, sub_context').eq('load_id', loadId).eq('inventory_id', src).maybeSingle();
  if (!flag?.sub_needed) return { ok: false, error: 'That line isn\'t flagged for a substitution' };
  const ctx: any[] = Array.isArray(flag.sub_context?.lines) ? flag.sub_context.lines : [];

  // Validate each customer line against what the flag recorded (never trust the browser for customer or order).
  const rows: any[] = [];
  for (const [shipment, qty] of want) {
    const c = ctx.find(z => String(z.shipment) === shipment);
    if (!c) return { ok: false, error: `Shipment ${shipment} isn't one of the customers on this flag` };
    if (qty > Number(c.qty)) return { ok: false, error: `${c.customer || c.customer_id}: ${qty} is more than the ${c.qty} they were short` };
    rows.push({ shipment, qty, c });
  }
  const acu = new Acu(t, `sub run ${env}`);
  try {
  await acu.login();
  const ir = await acu.call('GET', `/StockItem/${encodeURIComponent(sub)}`);
  const item = ir.ok ? ir.data : null;
  if (!item) return { ok: false, error: `Item ${sub} wasn't found in Acumatica` };
  if (v(item.ItemStatus) !== 'Active') return { ok: false, error: `Item ${sub} is ${v(item.ItemStatus)}, not Active` };
  const subDesc = v(item.Description), uom = v(item.SalesUOM) ?? v(item.BaseUOM);

  const prefix = env === 'live' ? 'SUB' : 'SUBT';
  const saved: any[] = [];
  for (const r of rows) {
    const ref = `${prefix}-${r.shipment}-${src}`;
    const { data: ex } = await admin.from('substitutions').select('*').eq('env', env).eq('load_id', loadId).eq('source_inventory_id', src).eq('orig_shipment_nbr', r.shipment).maybeSingle();
    if (ex) {
      if (ex.state === 'done') { saved.push(ex); continue; }
      // Item or quantity can change only before the SO exists.
      if (ex.step === 'none' && (ex.sub_inventory_id !== sub || Number(ex.qty) !== r.qty)) {
        const u = await admin.from('substitutions').update({ sub_inventory_id: sub, sub_description: subDesc, uom, qty: r.qty, updated_at: new Date().toISOString() }).eq('id', ex.id).select('*').single();
        saved.push(u.data); continue;
      }
      if (ex.sub_inventory_id !== sub) return { ok: false, error: `${r.c.customer || r.c.customer_id} already has ${ex.sub_inventory_id} started (SO ${ex.new_order_nbr ?? '?'}). Finish or cancel that one in Acumatica first.` };
      saved.push(ex); continue;
    }
    const ins = await admin.from('substitutions').insert({
      env, load_id: loadId, source_inventory_id: src, orig_shipment_nbr: r.shipment, orig_order_type: r.c.order_type ?? 'SO',
      orig_order_nbr: r.c.order_nbr ?? null, orig_order_line: r.c.order_line ?? null, customer_id: r.c.customer_id, customer_name: r.c.customer ?? null,
      sub_inventory_id: sub, sub_description: subDesc, uom, qty: r.qty, ref, requested_by: actor.id, requested_name: actor.name,
    }).select('*').single();
    if (ins.error) return { ok: false, error: `couldn't record the substitution: ${ins.error.message}` };
    saved.push(ins.data);
  }

  const started = Date.now();
    for (let i = 0; i < saved.length; i++) {
      const row = saved[i];
      if (row.state === 'done') continue;
      if (Date.now() - started > BUDGET_MS) { await setRow(row.id, { state: 'queued' }); continue; }
      const { data: orig } = await admin.from(env === 'live' ? 'shipments' : 'shipments_test').select('warehouse_id').eq('shipment_nbr', row.orig_shipment_nbr).maybeSingle();
      try { await runOne(acu, env, row, load, orig?.warehouse_id ?? '71'); }
      catch (e: any) { await setRow(row.id, { state: 'failed', error: String(e?.message ?? e).slice(0, 700) }).catch(() => {}); }
    }
  } catch (e: any) {
    return { ok: false, error: String(e?.message ?? e) };
  } finally { await acu.logout(); }

  const { data: out } = await admin.from('substitutions').select('*').eq('env', env).eq('load_id', loadId).eq('source_inventory_id', src).order('id');
  return { ok: true, rows: out ?? [] };
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
  if (!(roleRows ?? []).some(r => ROLES.includes(r.role))) return json({ ok: false, error: 'Only Invoicing staff can do substitutions' }, 403);
  const { data: prof } = await admin.from('profiles').select('full_name').eq('id', u.user.id).maybeSingle();
  const actor = { id: u.user.id as string, name: (prof?.full_name ?? u.user.email ?? 'unknown') as string };
  const env = p.env === 'live' ? 'live' : 'test';

  try {
    switch (p.action) {
      case 'status':
        return json({ ok: true, test: TARGETS.test.check() === null, test_why: TARGETS.test.check(), live: TARGETS.live.check() === null, live_why: TARGETS.live.check() });
      case 'search_items':
        return json(await searchItems(env, String(p.q ?? '')));
      case 'run':
        return json(await run(env, p, actor));
      default:
        return json({ ok: false, error: `unknown action ${p.action}` }, 400);
    }
  } catch (e: any) {
    console.error('dispatch-sub', p.action, e);
    return json({ ok: false, error: String(e?.message ?? e) }, 500);
  }
});
