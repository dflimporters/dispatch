// Supabase Edge Function: sync-invoice-print
// Reads invoices from the Acumatica contract-based REST API (endpoint Default/24.200.001: entities Invoice and
// SalesInvoice, see docs/invoice-print-gi.md) and stores whole invoices in invoice_print_headers /
// invoice_print_lines, which the invoice print layout reads through invoice_print_fetch().
// (The Generic Inquiry OData feed hangs on live, hence REST.)
//
// Body (all optional):
//   {}                      sync invoices with Date in [today - 7, today + 7], plus any invoice whose
//                           LastModifiedDateTime is newer than the newest one stored
//   { days_back: 30 }       widen the date window backwards (the 7 days ahead stays)
//   { links: true, days_back: 3 }  only the invoice -> shipment/order links (table invoice_shipments), no lines
//   { refs: ['1059165'] }   refresh just these invoices (used just before printing); the date window is skipped
//   { probe: '1059165' }    diagnostics: returns the raw REST JSON for that invoice from Invoice and SalesInvoice,
//                           plus the entities' field lists ($adHocSchema). Stores nothing.
//
// One Acumatica API login per run (the API session limit is small); logged out in a finally block.
// Runs to completion and returns JSON counts, so the page can wait for it before printing.
//
// Whole invoices only: when an invoice is re-synced its lines are deleted and re-inserted, so lines removed in
// Acumatica vanish here too.
//
// Secrets: ACUMATICA_USERNAME / ACUMATICA_PASSWORD (the same ones sync-so-invoices uses). Optional
// ACU_LIVE_TENANT (the tenant to log in to; default 'DFL Importers'). Values are never logged.
//
// TODO: TEST tenant. Like sync-so-invoices this reads the live tenant only; keep TEST rows out of the live tables.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const ACUMATICA_BASE_URL   = 'https://dflimporters.acumatica.com';
const ACUMATICA_USERNAME   = Deno.env.get('ACUMATICA_USERNAME')!;
const ACUMATICA_PASSWORD   = Deno.env.get('ACUMATICA_PASSWORD')!;
const ACUMATICA_COMPANY    = Deno.env.get('ACU_LIVE_TENANT') ?? 'DFL Importers';
const SUPABASE_URL         = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const ENTITY = `${ACUMATICA_BASE_URL}/entity/Default/24.200.001`;
const PAGE_SIZE  = 100;
const DAYS_BACK  = 7;
const DAYS_AHEAD = 7;
const MAX_REFS   = 200;
const REF_CHUNK  = 10;   // refs per $filter, keeps the URL short and the payload small

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, apikey',
};

// Country names for the address block (REST returns the Acumatica country code).
const COUNTRY_NAMES: Record<string, string> = { JM: 'Jamaica' };

// ── REST session ───────────────────────────────────────────────────────────
let cookie = '';

function takeCookies(res: Response) {
  const list: string[] = (res.headers as any).getSetCookie?.() ?? [];
  if (list.length === 0) return;
  const jar = new Map<string, string>();
  for (const c of cookie.split('; ').filter(Boolean)) { const i = c.indexOf('='); jar.set(c.slice(0, i), c.slice(i + 1)); }
  for (const c of list) { const kv = c.split(';')[0]; const i = kv.indexOf('='); jar.set(kv.slice(0, i), kv.slice(i + 1)); }
  cookie = [...jar].map(([k, v]) => `${k}=${v}`).join('; ');
}

async function login() {
  const res = await fetch(`${ACUMATICA_BASE_URL}/entity/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({ name: ACUMATICA_USERNAME, password: ACUMATICA_PASSWORD, company: ACUMATICA_COMPANY }),
  });
  if (!res.ok) throw new Error(`Acumatica login failed: ${res.status}`);
  takeCookies(res);
  await res.text();
}

async function logout() {
  if (!cookie) return;
  try {
    const res = await fetch(`${ACUMATICA_BASE_URL}/entity/auth/logout`, { method: 'POST', headers: { Cookie: cookie } });
    await res.text();
  } catch (e) { console.error('Acumatica logout failed:', (e as Error)?.message); }
  cookie = '';
}

async function rest(path: string, params: Record<string, string> = {}): Promise<any> {
  const url = new URL(`${ENTITY}/${path}`);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  console.log(`GET ${path} ${Object.entries(params).map(([k, v]) => `${k}=${v}`).join(' ')}`);
  const res = await fetch(url.toString(), { headers: { Cookie: cookie, Accept: 'application/json' } });
  takeCookies(res);
  if (!res.ok) {
    const body = (await res.text()).slice(0, 500);
    throw new Error(`REST ${path} failed: ${res.status} - ${body}`);
  }
  return res.json();
}

// ── helpers ────────────────────────────────────────────────────────────────
// REST fields arrive as { value: x }; take the first of the names that is present.
function v(o: any, ...names: string[]): any {
  if (!o) return null;
  for (const k of names) {
    const f = o[k];
    if (f == null) continue;
    const x = (typeof f === 'object' && !Array.isArray(f) && 'value' in f) ? f.value : f;
    if (x != null && typeof x !== 'object') return x;
  }
  return null;
}

function t(val: any): string | null {
  if (val == null) return null;
  const s = String(val).trim();
  return s === '' ? null : s;
}

function n(val: any): number | null {
  if (val == null || val === '') return null;
  const x = typeof val === 'number' ? val : parseFloat(String(val));
  return Number.isFinite(x) ? x : null;
}

function dateOnly(val: any): string | null {
  const s = t(val);
  return s ? s.split('T')[0] : null;
}

function isoDay(d: Date): string { return d.toISOString().split('T')[0]; }

function esc(s: string): string { return s.replace(/'/g, "''"); }

// Page through a list endpoint ($top/$skip).
async function listAll(entity: string, params: Record<string, string>): Promise<any[]> {
  const out: any[] = [];
  for (let skip = 0; ; skip += PAGE_SIZE) {
    const rows = await rest(entity, { ...params, $top: String(PAGE_SIZE), $skip: String(skip) });
    const arr: any[] = Array.isArray(rows) ? rows : (rows.value ?? []);
    out.push(...arr);
    if (arr.length < PAGE_SIZE) break;
  }
  return out;
}

// { name, lines[] } for the bill-to / ship-to block, as the layout expects it.
function addressBlock(contact: any, addr: any) {
  const city = [t(v(addr, 'City')), t(v(addr, 'State')), t(v(addr, 'PostalCode'))].filter(Boolean).join(' ');
  const cc = t(v(addr, 'Country', 'CountryID'));
  const lines = [t(v(addr, 'AddressLine1')), t(v(addr, 'AddressLine2')), city || null, cc ? (COUNTRY_NAMES[cc] ?? cc) : null]
    .filter((x): x is string => !!x);
  return { name: t(v(contact, 'BusinessName', 'FullName', 'Attention')), lines };
}

// ── fetch + map ────────────────────────────────────────────────────────────
// Invoice: money, terms, per-line TaxCategory/UOM/prices. SalesInvoice: bill/ship blocks, order and shipment numbers.
// Both are read for the same invoices (by ref list, or by date / modified filter) and merged by ReferenceNbr.
const TYPE = "Type eq 'Invoice'";
const SALES_EXPAND = 'Details,BillToContact,BillToAddress,ShipToContact,ShipToAddress';

async function fetchPair(filter: string): Promise<{ inv: any[]; sales: Map<string, any> }> {
  const inv = await listAll('Invoice', { $filter: `${TYPE} and (${filter})`, $expand: 'Details' });
  const sales = new Map<string, any>();
  if (inv.length === 0) return { inv, sales };
  const refs = inv.map(i => String(v(i, 'ReferenceNbr')));
  for (let i = 0; i < refs.length; i += REF_CHUNK) {
    const f = refs.slice(i, i + REF_CHUNK).map(r => `ReferenceNbr eq '${esc(r)}'`).join(' or ');
    const rows = await listAll('SalesInvoice', { $filter: `${TYPE} and (${f})`, $expand: SALES_EXPAND });
    for (const r of rows) sales.set(String(v(r, 'ReferenceNbr')), r);
  }
  return { inv, sales };
}

// ShipVia lives on the shipment (not on the invoice). One lookup per distinct shipment, best effort.
async function shipViaFor(shipmentNbrs: string[]): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  const nbrs = [...new Set(shipmentNbrs)];
  for (let i = 0; i < nbrs.length; i += REF_CHUNK) {
    const f = nbrs.slice(i, i + REF_CHUNK).map(r => `ShipmentNbr eq '${esc(r)}'`).join(' or ');
    try {
      const rows = await listAll('Shipment', { $filter: f, $select: 'ShipmentNbr,ShipVia' });
      for (const r of rows) { const via = t(v(r, 'ShipVia')); if (via) out.set(String(v(r, 'ShipmentNbr')), via); }
    } catch (e) { console.error('ShipVia lookup failed:', (e as Error)?.message); break; }
  }
  return out;
}

type OrderInfo = { sp: string | null; po: string | null; ref: string | null };

// Salesperson and customer PO live on the sales order. One lookup per distinct SO, best effort.
async function orderInfoFor(orderNbrs: string[]): Promise<Map<string, OrderInfo>> {
  const out = new Map<string, OrderInfo>();
  const nbrs = [...new Set(orderNbrs)];
  for (let i = 0; i < nbrs.length; i += REF_CHUNK) {
    const f = nbrs.slice(i, i + REF_CHUNK).map(r => `OrderNbr eq '${esc(r)}'`).join(' or ');
    try {
      // no header salesperson in the entity: it is per line (Details.SalespersonID); take the first line's
      const rows = await listAll('SalesOrder', { $filter: `OrderType eq 'SO' and (${f})`, $expand: 'Details' });
      for (const r of rows) {
        const d = (r.Details ?? []).find((x: any) => t(v(x, 'SalespersonID')));
        out.set(String(v(r, 'OrderNbr')), { sp: t(v(d, 'SalespersonID')), po: t(v(r, 'CustomerOrder')), ref: t(v(r, 'ExternalRef', 'CustomerRefNbr')) });
      }
    } catch (e) { console.error('Order lookup failed:', (e as Error)?.message); break; }
  }
  return out;
}

// Bill-to contact is null when it inherits the customer's, so the name comes from the Customer entity.
async function customerNames(ids: string[]): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  const list = [...new Set(ids)];
  for (let i = 0; i < list.length; i += REF_CHUNK) {
    const f = list.slice(i, i + REF_CHUNK).map(r => `CustomerID eq '${esc(r)}'`).join(' or ');
    try {
      const rows = await listAll('Customer', { $filter: f, $select: 'CustomerID,CustomerName' });
      for (const r of rows) { const nm = t(v(r, 'CustomerName')); if (nm) out.set(String(v(r, 'CustomerID')), nm); }
    } catch (e) { console.error('Customer lookup failed:', (e as Error)?.message); break; }
  }
  return out;
}

// The REST API has no Terms entity, so the printed description is derived from the terms ID ('30DAYS' -> 'Due in 30 Days').
function termsDescr(id: string | null): string | null {
  if (!id) return null;
  const m = /^(\d+)\s*DAYS?$/i.exec(id);
  return m ? `Due in ${m[1]} Days` : id;
}

function taxCat(raw: any): string | null {
  const s = t(raw);
  if (!s) return null;
  const u = s.toUpperCase();
  return u === 'TX' ? 'TAXABLE' : u === 'NT' ? 'NONTAXABLE' : u;
}

type Link = { reference_number: string; shipment_nbr: string; order_nbr: string };
type Mapped = Map<string, { header: any; lines: Map<number, any>; links: Link[] }>;

// One (shipment, order) pair per distinct combination on the invoice's lines. This is what ties an invoice to its
// shipment(s) even when the header OrderNbr is blank (an invoice that spans several orders).
function linksOf(ref: string, details: any[]): Link[] {
  const seen = new Map<string, Link>();
  for (const d of details) {
    const sh = t(v(d, 'ShipmentNbr')); if (!sh) continue;
    const so = t(v(d, 'OrderNbr')) ?? '';
    seen.set(`${sh}|${so}`, { reference_number: ref, shipment_nbr: sh, order_nbr: so });
  }
  return [...seen.values()];
}

async function replaceLinks(ref: string, links: Link[]) {
  const { error: delErr } = await supabase.from('invoice_shipments').delete().eq('reference_number', ref);
  if (delErr) throw new Error(`Link delete error (${ref}): ${delErr.message}`);
  if (links.length) {
    const { error: insErr } = await supabase.from('invoice_shipments').insert(links);
    if (insErr) throw new Error(`Link insert error (${ref}): ${insErr.message}`);
  }
}

// Links only (no lines, addresses or lookups): the cheap refresh the invoicing page asks for when a row is pending.
// Cancelled invoices are stored too; the lookup function skips them.
async function syncLinks(daysBack: number) {
  const from = new Date(); from.setDate(from.getDate() - daysBack);
  const to = new Date(); to.setDate(to.getDate() + DAYS_AHEAD);
  const filter = `Date ge datetimeoffset'${isoDay(from)}T00:00:00Z' and Date le datetimeoffset'${isoDay(to)}T23:59:59Z'`;
  const rows = await listAll('SalesInvoice', { $filter: `${TYPE} and (${filter})`, $expand: 'Details', $select: 'ReferenceNbr,Details/ShipmentNbr,Details/OrderNbr' });
  // Batched (a window is a few hundred invoices): one delete and one insert per chunk, not one pair per invoice.
  const refs: string[] = [], all: Link[] = [];
  for (const r of rows) {
    const ref = t(v(r, 'ReferenceNbr')); if (!ref) continue;
    refs.push(ref); all.push(...linksOf(ref, r.Details ?? []));
  }
  for (let i = 0; i < refs.length; i += 200) {
    const { error } = await supabase.from('invoice_shipments').delete().in('reference_number', refs.slice(i, i + 200));
    if (error) throw new Error(`Link delete error: ${error.message}`);
  }
  for (let i = 0; i < all.length; i += 500) {
    const { error } = await supabase.from('invoice_shipments').insert(all.slice(i, i + 500));
    if (error) throw new Error(`Link insert error: ${error.message}`);
  }
  return { link_invoices: refs.length, links: all.length, date_from: isoDay(from) };
}

async function mapInvoices(inv: any[], sales: Map<string, any>): Promise<Mapped> {
  const byRef: Mapped = new Map();
  const now = new Date().toISOString();

  // second sources
  const shipments: string[] = [], orders: string[] = [];
  for (const s of sales.values()) for (const d of (s.Details ?? [])) {
    const sh = t(v(d, 'ShipmentNbr')); if (sh) shipments.push(sh);
    const so = t(v(d, 'OrderNbr')); if (so) orders.push(so);
  }
  const custIds = inv.map(i => t(v(i, 'Customer', 'CustomerID'))).filter((x): x is string => !!x);
  const [viaMap, orderMap, custMap] = await Promise.all([shipViaFor(shipments), orderInfoFor(orders), customerNames(custIds)]);

  for (const i of inv) {
    const ref = t(v(i, 'ReferenceNbr'));
    if (!ref) continue;
    const s = sales.get(ref);
    const sDetails: any[] = s?.Details ?? [];
    const sBy = new Map<number, any>();
    for (const d of sDetails) { const ln = n(v(d, 'LineNbr')); if (ln != null) sBy.set(ln, d); }
    const first = sDetails.find(d => t(v(d, 'OrderNbr')) || t(v(d, 'ShipmentNbr'))) ?? null;
    const soNbr = t(v(first, 'OrderNbr'));
    const shNbr = t(v(first, 'ShipmentNbr'));
    const oi = soNbr ? orderMap.get(soNbr) : undefined;

    const custId = t(v(i, 'Customer', 'CustomerID'));
    const custName = custId ? custMap.get(custId) ?? null : null;
    const bill = addressBlock(s?.BillToContact, s?.BillToAddress);
    const ship = addressBlock(s?.ShipToContact, s?.ShipToAddress);
    const header = {
      ref,
      doc_type:      'INV',
      doc_date:      dateOnly(v(i, 'Date')),
      due_date:      dateOnly(v(i, 'DueDate')),
      status:        t(v(i, 'Status')),
      customer_id:   custId,
      customer_name: custName,
      currency:      t(v(s, 'Currency')) ?? t(v(i, 'Currency')),
      terms:         termsDescr(t(v(i, 'Terms'))),
      salesperson:   oi?.sp ?? null,
      so_number:     soNbr,
      shipment_nbr:  shNbr,
      customer_po:   oi?.po ?? null,
      customer_ref:  oi?.ref ?? null,
      ship_via:      shNbr ? viaMap.get(shNbr) ?? null : null,
      bill:          { name: bill.name ?? custName, lines: bill.lines },
      ship:          { name: ship.name ?? bill.name ?? custName, lines: ship.lines },
      sales_total:   n(v(s, 'DetailTotal')),
      discount_total: n(v(s, 'DiscountTotal')) ?? 0,
      tax_total:     n(v(i, 'TaxTotal')),
      total:         n(v(i, 'Amount')),
      last_modified: t(v(i, 'LastModifiedDateTime')),
      synced_at:     now,
    };

    const lines = new Map<number, any>();
    for (const d of (i.Details ?? [])) {
      const lineNbr = n(v(d, 'LineNbr'));
      if (lineNbr == null) continue;
      const qty = n(v(d, 'Qty', 'Quantity'));
      if (qty === 0) continue; // void lines
      const sd = sBy.get(lineNbr);
      lines.set(lineNbr, {
        ref,
        line_nbr:     lineNbr,
        inventory_cd: t(v(d, 'InventoryID')),
        descr:        t(v(d, 'TransactionDescription')),
        qty,
        uom:          t(v(d, 'UOM')),
        unit_price:   n(v(d, 'UnitPrice')),
        tax_cat:      taxCat(v(d, 'TaxCategory') ?? v(sd, 'TaxCategory')),
        amount:       n(v(d, 'ExtendedPrice', 'Amount')),
        discount:     n(v(d, 'DiscountAmount')) ?? 0,
        note:         null,   // line notes are not printed
      });
    }
    byRef.set(ref, { header, lines, links: linksOf(ref, sDetails) });
  }
  return byRef;
}

async function storeInvoices(byRef: Mapped): Promise<{ invoices: number; lines: number }> {
  let invoices = 0, lines = 0;

  for (const [ref, inv] of byRef) {
    // Replace the lines first so lines removed in Acumatica vanish, then upsert the header.
    const { error: delErr } = await supabase.from('invoice_print_lines').delete().eq('ref', ref);
    if (delErr) throw new Error(`Line delete error (${ref}): ${delErr.message}`);

    const lineRows = [...inv.lines.values()];
    if (lineRows.length > 0) {
      const { error: insErr } = await supabase.from('invoice_print_lines').insert(lineRows);
      if (insErr) throw new Error(`Line insert error (${ref}): ${insErr.message}`);
    }

    const { error: hdrErr } = await supabase
      .from('invoice_print_headers')
      .upsert(inv.header, { onConflict: 'ref', ignoreDuplicates: false });
    if (hdrErr) throw new Error(`Header upsert error (${ref}): ${hdrErr.message}`);

    await replaceLinks(ref, inv.links);

    invoices++;
    lines += lineRows.length;
  }
  return { invoices, lines };
}

// Newest LastModified stored so far (ISO, for a datetimeoffset literal), or null if none.
async function newestStored(): Promise<string | null> {
  const { data, error } = await supabase
    .from('invoice_print_headers')
    .select('last_modified')
    .not('last_modified', 'is', null)
    .order('last_modified', { ascending: false })
    .limit(1);
  if (error) throw new Error(`Newest last_modified lookup failed: ${error.message}`);
  const x = data?.[0]?.last_modified;
  return x ? new Date(x).toISOString() : null;
}

function cleanRefs(raw: any): string[] {
  if (!Array.isArray(raw)) throw new Error('refs must be an array');
  const refs = [...new Set(raw.map(r => String(r ?? '').trim()).filter(r => r !== ''))];
  if (refs.length === 0) throw new Error('refs is empty');
  if (refs.length > MAX_REFS) throw new Error(`At most ${MAX_REFS} refs at a time`);
  for (const r of refs) {
    if (!/^[A-Za-z0-9_.-]+$/.test(r)) throw new Error(`Bad invoice number: ${r}`);
  }
  return refs;
}

async function runProbe(ref: string) {
  const f = `ReferenceNbr eq '${esc(ref)}' and ${TYPE}`;
  const err = (e: any) => ({ error: String(e.message) });
  const [invoice, salesInvoice, invSchema, salesSchema] = await Promise.all([
    rest('Invoice', { $filter: f, $expand: 'Details' }).catch(err),
    rest('SalesInvoice', { $filter: f, $expand: SALES_EXPAND }).catch(err),
    rest('Invoice/$adHocSchema').catch(err),
    rest('SalesInvoice/$adHocSchema').catch(err),
  ]);
  return { invoice, salesInvoice, invSchema, salesSchema };
}

// ── MAIN ───────────────────────────────────────────────────────────────────
async function runSync(body: any) {
  const result: Record<string, any> = {};

  if (body?.probe !== undefined) return await runProbe(cleanRefs([body.probe])[0]);

  if (body?.links) {
    const d = Number(body.days_back);
    return await syncLinks(Number.isFinite(d) && d >= 0 ? Math.min(Math.floor(d), 400) : 3);
  }

  if (body?.refs !== undefined) {
    const refs = cleanRefs(body.refs);
    const grouped: Mapped = new Map();
    for (let i = 0; i < refs.length; i += REF_CHUNK) {
      const filter = refs.slice(i, i + REF_CHUNK).map(r => `ReferenceNbr eq '${esc(r)}'`).join(' or ');
      const { inv, sales } = await fetchPair(filter);
      for (const [k, x] of await mapInvoices(inv, sales)) grouped.set(k, x);
    }
    result.refs_requested = refs.length;
    result.not_found = refs.filter(r => !grouped.has(r));
    Object.assign(result, await storeInvoices(grouped));
    return result;
  }

  const daysBack = Number.isFinite(Number(body?.days_back)) && Number(body.days_back) >= 0
    ? Math.min(Math.floor(Number(body.days_back)), 400)
    : DAYS_BACK;
  const from = new Date(); from.setDate(from.getDate() - daysBack);
  const to = new Date(); to.setDate(to.getDate() + DAYS_AHEAD);
  const dateFrom = `${isoDay(from)}T00:00:00Z`;
  const dateTo   = `${isoDay(to)}T23:59:59Z`;
  console.log(`Starting sync: ${dateFrom} to ${dateTo}`);

  const grouped: Mapped = new Map();
  const win = await fetchPair(`Date ge datetimeoffset'${dateFrom}' and Date le datetimeoffset'${dateTo}'`);
  for (const [k, x] of await mapInvoices(win.inv, win.sales)) grouped.set(k, x);
  result.window_invoices = win.inv.length;

  // Invoices changed since the newest one stored, whatever their date (skipped on an empty table).
  const since = await newestStored();
  if (since) {
    const ch = await fetchPair(`LastModifiedDateTime gt datetimeoffset'${since}'`);
    for (const [k, x] of await mapInvoices(ch.inv, ch.sales)) grouped.set(k, x);
    result.changed_invoices = ch.inv.length;
  }

  Object.assign(result, await storeInvoices(grouped));
  result.date_from = dateFrom;
  result.date_to = dateTo;
  result.changed_since = since;
  console.log(`Sync complete. Invoices: ${result.invoices}, lines: ${result.lines}`);
  return result;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });

  // Supervisor or manager only (the people who print invoices). verify_jwt may be on or off; the token is checked here.
  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
  let body: any = {};
  if (req.method === 'POST') {
    try { body = await req.json(); } catch { body = {}; }
  }
  const { data: u } = token ? await supabase.auth.getUser(token) : { data: null } as any;
  const { data: roleRows } = u?.user ? await supabase.from('dispatch_roles').select('role').eq('user_id', u.user.id) : { data: [] } as any;
  if (!(roleRows ?? []).some((r: any) => ['supervisor', 'manager', 'invoicer'].includes(r.role))) {
    return new Response(JSON.stringify({ success: false, error: 'Only a supervisor, manager or invoicing clerk can refresh invoices for printing' }), {
      status: 403, headers: { 'Content-Type': 'application/json', ...CORS },
    });
  }

  try {
    await login();
    const result = await runSync(body ?? {});
    return new Response(JSON.stringify({ success: true, ...result }), { headers: { 'Content-Type': 'application/json', ...CORS } });
  } catch (err) {
    console.error('Sync failed:', err);
    return new Response(JSON.stringify({ success: false, error: String((err as Error)?.message ?? err) }), {
      status: 500, headers: { 'Content-Type': 'application/json', ...CORS },
    });
  } finally {
    await logout();
  }
});
