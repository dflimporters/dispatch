// Supabase Edge Function: sync-invoice-print
// Pulls the Acumatica Generic Inquiry DFLInvoicePrint (one row per invoice line; see docs/invoice-print-gi.md)
// and stores whole invoices in invoice_print_headers / invoice_print_lines, which the invoice print layout reads
// through invoice_print_fetch().
//
// Body (all optional):
//   {}                      sync invoices with DocDate in [today - 7, today + 7], plus any invoice whose
//                           LastModified is newer than the newest one stored
//   { days_back: 30 }       widen the date window backwards (the 7 days ahead stays)
//   { refs: ['1059165'] }   refresh just these invoices (used just before printing); the date window is skipped
//
// Runs to completion and returns JSON counts (unlike sync-so-invoices, which answers first and works in the
// background), so the page can wait for it before printing.
//
// Whole invoices only: when an invoice is re-synced its lines are deleted and re-inserted, so lines removed in
// Acumatica vanish here too.
//
// TODO: TEST tenant. Like sync-so-invoices this reads the live OData endpoint only. To read TEST, point
// ODATA_ENDPOINT at the TEST tenant name and credentials (the way dispatch-orders picks its target) and
// keep TEST rows out of the live tables (or add an env column).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const ACUMATICA_BASE_URL   = 'https://dflimporters.acumatica.com';
const ACUMATICA_USERNAME   = Deno.env.get('ACUMATICA_USERNAME')!;
const ACUMATICA_PASSWORD   = Deno.env.get('ACUMATICA_PASSWORD')!;
const SUPABASE_URL         = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const ODATA_ENDPOINT = `${ACUMATICA_BASE_URL}/odata/dfl%20importers/DFLInvoicePrint`;
const BATCH_SIZE = 500;
const DAYS_BACK  = 7;
const DAYS_AHEAD = 7;
const MAX_REFS   = 200;
const REF_CHUNK  = 20;   // refs per OData $filter, keeps the URL short

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, apikey',
};

// Country names for the address block (the GI returns the Acumatica country code).
const COUNTRY_NAMES: Record<string, string> = { JM: 'Jamaica' };

function basicAuthHeader(): string {
  return `Basic ${btoa(`${ACUMATICA_USERNAME}:${ACUMATICA_PASSWORD}`)}`;
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

function isoDay(d: Date): string {
  return d.toISOString().split('T')[0];
}

function getDateFrom(daysBack: number): string {
  const d = new Date();
  d.setDate(d.getDate() - daysBack);
  return isoDay(d) + 'T00:00:00';
}

function getDateTo(): string {
  const d = new Date();
  d.setDate(d.getDate() + DAYS_AHEAD);
  return isoDay(d) + 'T23:59:59';
}

async function fetchPage(filter: string, skip: number): Promise<any[]> {
  const url = new URL(ODATA_ENDPOINT);
  url.searchParams.set('$filter',  filter);
  url.searchParams.set('$orderby', 'RefNbr,LineNbr');
  url.searchParams.set('$top',     String(BATCH_SIZE));
  url.searchParams.set('$skip',    String(skip));
  url.searchParams.set('$format',  'json');

  console.log(`Fetching ${ODATA_ENDPOINT} skip=${skip} filter=${filter}`);

  const res = await fetch(url.toString(), {
    headers: { Authorization: basicAuthHeader(), Accept: 'application/json' },
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`OData fetch failed: ${res.status} - ${body}`);
  }

  const json = await res.json();
  return Array.isArray(json) ? json : (json.value ?? []);
}

async function fetchAll(filter: string): Promise<any[]> {
  const out: any[] = [];
  let skip = 0;
  while (true) {
    const rows = await fetchPage(filter, skip);
    if (rows.length === 0) break;
    out.push(...rows);
    if (rows.length < BATCH_SIZE) break;
    skip += BATCH_SIZE;
  }
  return out;
}

// { name, lines[] } for the bill-to / ship-to block, as the layout expects it.
function addressBlock(r: any, p: 'Bill' | 'Ship') {
  const city = [t(r[`${p}City`]), t(r[`${p}State`]), t(r[`${p}Postal`])].filter(Boolean).join(' ');
  const cc = t(r[`${p}Country`]);
  const lines = [t(r[`${p}Address1`]), t(r[`${p}Address2`]), city || null, cc ? (COUNTRY_NAMES[cc] ?? cc) : null]
    .filter((x): x is string => !!x);
  return { name: t(r[`${p}Name`]), lines };
}

// Group GI rows (one per line) into invoices. The same ref:line can come back from more than one pass; the last wins.
function groupInvoices(rows: any[]) {
  const byRef = new Map<string, { header: any; lines: Map<number, any> }>();
  const now = new Date().toISOString();

  for (const r of rows) {
    const ref = t(r.RefNbr);
    if (!ref) continue;
    let inv = byRef.get(ref);
    if (!inv) {
      inv = {
        header: {
          ref,
          doc_type:      t(r.DocType) ?? 'INV',
          doc_date:      dateOnly(r.DocDate),
          due_date:      dateOnly(r.DueDate),
          status:        t(r.Status),
          customer_id:   t(r.CustomerID),
          customer_name: t(r.CustomerName),
          currency:      t(r.CurrencyID),
          terms:         t(r.TermsDescr) ?? t(r.TermsID),
          salesperson:   t(r.SalesPersonID),
          so_number:     t(r.SONumber),
          shipment_nbr:  t(r.ShipmentNbr),
          customer_po:   t(r.CustomerPO),
          customer_ref:  t(r.CustomerRefNbr),
          ship_via:      t(r.ShipVia),
          bill:          addressBlock(r, 'Bill'),
          ship:          addressBlock(r, 'Ship'),
          sales_total:   n(r.SalesTotal),
          discount_total: n(r.DiscountTotal),
          tax_total:     n(r.TaxTotal),
          total:         n(r.DocTotal),
          last_modified: t(r.LastModified),
          synced_at:     now,
        },
        lines: new Map(),
      };
      byRef.set(ref, inv);
    }
    const lineNbr = n(r.LineNbr);
    if (lineNbr == null) continue;
    inv.lines.set(lineNbr, {
      ref,
      line_nbr:     lineNbr,
      inventory_cd: t(r.InventoryCD),
      descr:        t(r.LineDescr),
      qty:          n(r.Qty),
      uom:          t(r.UOM),
      unit_price:   n(r.UnitPrice),
      tax_cat:      t(r.TaxCategory),
      amount:       n(r.ExtAmount),
      discount:     n(r.LineDiscount),
      note:         t(r.LineNote),
    });
  }
  return byRef;
}

async function storeInvoices(byRef: Map<string, { header: any; lines: Map<number, any> }>): Promise<{ invoices: number; lines: number }> {
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

    invoices++;
    lines += lineRows.length;
  }
  return { invoices, lines };
}

// Newest LastModified stored so far, as an OData datetime literal body (no offset, no fraction), or null if none.
async function newestStored(): Promise<string | null> {
  const { data, error } = await supabase
    .from('invoice_print_headers')
    .select('last_modified')
    .not('last_modified', 'is', null)
    .order('last_modified', { ascending: false })
    .limit(1);
  if (error) throw new Error(`Newest last_modified lookup failed: ${error.message}`);
  const v = data?.[0]?.last_modified;
  return v ? String(v).slice(0, 19) : null;
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

// ── MAIN ───────────────────────────────────────────────────────────────────
async function runSync(body: any) {
  const rows: any[] = [];
  const result: Record<string, any> = {};

  if (body?.refs !== undefined) {
    const refs = cleanRefs(body.refs);
    for (let i = 0; i < refs.length; i += REF_CHUNK) {
      const chunk = refs.slice(i, i + REF_CHUNK);
      const filter = chunk.map(r => `RefNbr eq '${r.replace(/'/g, "''")}'`).join(' or ');
      rows.push(...await fetchAll(filter));
    }
    const grouped = groupInvoices(rows);
    result.refs_requested = refs.length;
    result.not_found = refs.filter(r => !grouped.has(r));
    Object.assign(result, await storeInvoices(grouped));
    return result;
  }

  const daysBack = Number.isFinite(Number(body?.days_back)) && Number(body.days_back) >= 0
    ? Math.min(Math.floor(Number(body.days_back)), 400)
    : DAYS_BACK;
  const dateFrom = getDateFrom(daysBack);
  const dateTo   = getDateTo();
  console.log(`Starting sync: ${dateFrom} to ${dateTo}`);

  const windowRows = await fetchAll(`DocDate ge datetime'${dateFrom}' and DocDate le datetime'${dateTo}'`);
  rows.push(...windowRows);

  // Invoices changed since the newest one stored, whatever their date (skipped on an empty table).
  const since = await newestStored();
  let changedRows = 0;
  if (since) {
    const changed = await fetchAll(`LastModified gt datetime'${since}'`);
    changedRows = changed.length;
    rows.push(...changed);
  }

  const grouped = groupInvoices(rows);
  Object.assign(result, await storeInvoices(grouped));
  result.date_from = dateFrom;
  result.date_to = dateTo;
  result.window_rows = windowRows.length;
  result.changed_rows = changedRows;
  result.changed_since = since;
  console.log(`Sync complete. Invoices: ${result.invoices}, lines: ${result.lines}`);
  return result;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });

  let body: any = {};
  if (req.method === 'POST') {
    try { body = await req.json(); } catch { body = {}; }
  }

  try {
    const result = await runSync(body ?? {});
    return new Response(JSON.stringify({ success: true, ...result }), { headers: { 'Content-Type': 'application/json', ...CORS } });
  } catch (err) {
    console.error('Sync failed:', err);
    return new Response(JSON.stringify({ success: false, error: String((err as Error)?.message ?? err) }), {
      status: 500, headers: { 'Content-Type': 'application/json', ...CORS },
    });
  }
});
