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
          await acu.action('/SalesOrder/SalesOrderCreateShipment', { entity: { id: before.data.id }, parameters: { ShipmentDate: { value: date } } });
          const after = await acu.call('GET', url);
          if (!after.ok) throw new Error(`created, but couldn't read ${nbr} back: ${after.status} ${acuError(after.data)}`);
          const fresh = shipmentsOf(after.data).filter(s => !had.has(s));
          const nowStatus = v(after.data?.Status);
          r = fresh.length
            ? { order_nbr: nbr, state: 'created', shipments: fresh, detail: `Order is ${nowStatus}` }
            : nowStatus !== status
              ? { order_nbr: nbr, state: 'created', detail: `Order moved to ${nowStatus}; the shipment number wasn't returned (see the Coordinator page after the next sync)` }
              : { order_nbr: nbr, state: 'none', detail: 'Acumatica made no shipment (nothing available to ship?)' };
        }
      } catch (e: any) { r = { order_nbr: nbr, state: 'failed', detail: String(e?.message ?? e).slice(0, 400) }; }
      results.push(r);
      await record(r);
    }
  } catch (e: any) {
    return { ok: false, error: String(e?.message ?? e), results };
  } finally { await acu.logout(); }
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
      case 'create_shipments': {
        const env = p.env === 'live' ? 'live' : 'test';
        const date = String(p.shipment_date ?? '');
        if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || date < jmToday()) return json({ ok: false, error: 'Shipment date must be today or later' }, 400);
        const orders = [...new Set((Array.isArray(p.orders) ? p.orders : []).map((o: any) => String(o).trim()).filter((o: string) => /^[A-Za-z0-9-]{1,15}$/.test(o)))] as string[];
        if (!orders.length || orders.length > 20) return json({ ok: false, error: 'Select 1 to 20 orders' }, 400);
        return json(await createShipments(env, orders, date, actor));
      }
      default:
        return json({ ok: false, error: `unknown action ${p.action}` }, 400);
    }
  } catch (e: any) {
    console.error('dispatch-orders', p.action, e);
    return json({ ok: false, error: String(e?.message ?? e) }, 500);
  }
});
