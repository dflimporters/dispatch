// Supabase Edge Function: sync-so-invoices
// 1. Pulls SO-Invoice headers from Acumatica and upserts into so_invoices
// 2. Pulls so-invoice-shipment GI and backfills ship_via where null
//
// 2026-10-24: window widened from 3 days back / 1 day ahead to 7 / 7. Invoices dated past tomorrow
// (e.g. Monday's run prepared on Friday) were never pulled in, so Load Sheets couldn't find them.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const ACUMATICA_BASE_URL   = 'https://dflimporters.acumatica.com';
const ACUMATICA_USERNAME   = Deno.env.get('ACUMATICA_USERNAME')!;
const ACUMATICA_PASSWORD   = Deno.env.get('ACUMATICA_PASSWORD')!;
const SUPABASE_URL         = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const INVOICE_ENDPOINT  = `${ACUMATICA_BASE_URL}/odata/dfl%20importers/SO-Invoice`;
const SHIPMENT_ENDPOINT = `${ACUMATICA_BASE_URL}/odata/dfl%20importers/so-invoice-shipment`;
const BATCH_SIZE = 500;
const DAYS_BACK  = 7;
const DAYS_AHEAD = 7;

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, apikey',
};

function basicAuthHeader(): string {
  return `Basic ${btoa(`${ACUMATICA_USERNAME}:${ACUMATICA_PASSWORD}`)}`;
}

function t(val: any): string | null {
  if (val == null) return null;
  const s = String(val).trim();
  return s === '' ? null : s;
}

function getDateFrom(): string {
  const d = new Date();
  d.setDate(d.getDate() - DAYS_BACK);
  return d.toISOString().split('T')[0] + 'T00:00:00';
}

function getDateTo(): string {
  const d = new Date();
  d.setDate(d.getDate() + DAYS_AHEAD);
  return d.toISOString().split('T')[0] + 'T23:59:59';
}

async function fetchPage(endpoint: string, filter: string, select: string, skip: number): Promise<any[]> {
  const url = new URL(endpoint);
  url.searchParams.set('$filter',  filter);
  url.searchParams.set('$select',  select);
  url.searchParams.set('$top',     String(BATCH_SIZE));
  url.searchParams.set('$skip',    String(skip));
  url.searchParams.set('$format',  'json');

  console.log(`Fetching ${endpoint} skip=${skip}`);

  const res = await fetch(url.toString(), {
    headers: { Authorization: basicAuthHeader(), Accept: 'application/json' },
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`OData fetch failed: ${res.status} — ${body}`);
  }

  const json = await res.json();
  return Array.isArray(json) ? json : (json.value ?? []);
}

// ── STEP 1: Sync SO-Invoice headers ────────────────────────────────────────
async function syncInvoiceHeaders(dateFrom: string, dateTo: string): Promise<number> {
  let skip = 0, total = 0;

  while (true) {
    const rows = await fetchPage(
      INVOICE_ENDPOINT,
      `Type eq 'Invoice' and Date ge datetime'${dateFrom}' and Date le datetime'${dateTo}'`,
      'ReferenceNbr,OrderNbr,CustomerID,CustomerName,Status,Date,Amount,ShipVia,ShipViaDescription,Branch',
      skip
    );
    if (rows.length === 0) break;

    const transformed = rows
      .map(r => ({
        reference_number:     t(r.ReferenceNbr),
        order_number:         t(r.OrderNbr),
        customer_id:          t(r.CustomerID),
        customer_name:        t(r.CustomerName),
        status:               t(r.Status),
        invoice_date:         r.Date ? r.Date.split('T')[0] : null,
        invoice_amount:       r.Amount != null ? parseFloat(r.Amount) : null,
        ship_via:             t(r.ShipVia),
        ship_via_description: t(r.ShipViaDescription),
        branch:               t(r.Branch),
        synced_at:            new Date().toISOString(),
      }))
      .filter(r => r.reference_number != null);

    const { error } = await supabase
      .from('so_invoices')
      .upsert(transformed, { onConflict: 'reference_number', ignoreDuplicates: false });

    if (error) throw new Error(`Invoice upsert error: ${error.message}`);

    total += rows.length;
    console.log(`Invoice headers upserted: ${total}`);
    if (rows.length < BATCH_SIZE) break;
    skip += BATCH_SIZE;
  }

  return total;
}

// ── STEP 2: Backfill ShipVia from so-invoice-shipment GI ───────────────────
async function backfillShipVia(dateFrom: string, dateTo: string): Promise<number> {
  let skip = 0, total = 0;

  const shipViaMap: Record<string, { ship_via: string; ship_via_description: string | null }> = {};

  while (true) {
    const rows = await fetchPage(
      SHIPMENT_ENDPOINT,
      `TranType eq 'INV' and Date ge datetime'${dateFrom}' and Date le datetime'${dateTo}'`,
      'ReferenceNbr,ShipVia,Description,Date',
      skip
    );
    if (rows.length === 0) break;

    for (const r of rows) {
      const ref      = t(r.ReferenceNbr);
      const shipVia  = t(r.ShipVia);
      if (!ref || !shipVia) continue;
      if (!shipViaMap[ref]) {
        shipViaMap[ref] = {
          ship_via:             shipVia,
          ship_via_description: t(r.Description),
        };
      }
    }

    if (rows.length < BATCH_SIZE) break;
    skip += BATCH_SIZE;
  }

  console.log(`ShipVia map built: ${Object.keys(shipViaMap).length} unique invoices`);

  const { data: nullInvoices, error: fetchErr } = await supabase
    .from('so_invoices')
    .select('reference_number')
    .is('ship_via', null)
    .gte('invoice_date', dateFrom.split('T')[0])
    .lte('invoice_date', dateTo.split('T')[0]);

  if (fetchErr) throw new Error(`Failed to fetch null-ShipVia invoices: ${fetchErr.message}`);
  if (!nullInvoices || nullInvoices.length === 0) {
    console.log('No null ShipVia invoices to backfill');
    return 0;
  }

  console.log(`Found ${nullInvoices.length} invoices with null ShipVia to backfill`);

  for (const inv of nullInvoices) {
    const match = shipViaMap[inv.reference_number];
    if (!match) continue;

    const { error: updateErr } = await supabase
      .from('so_invoices')
      .update({
        ship_via:             match.ship_via,
        ship_via_description: match.ship_via_description,
        synced_at:            new Date().toISOString(),
      })
      .eq('reference_number', inv.reference_number)
      .is('ship_via', null);

    if (updateErr) {
      console.error(`Failed to update ShipVia for ${inv.reference_number}:`, updateErr.message);
    } else {
      total++;
    }
  }

  console.log(`ShipVia backfilled for ${total} invoices`);
  return total;
}

// ── MAIN ───────────────────────────────────────────────────────────────────
async function runSync() {
  const dateFrom = getDateFrom();
  const dateTo   = getDateTo();
  console.log(`Starting sync: ${dateFrom} to ${dateTo}`);

  const invoiceCount  = await syncInvoiceHeaders(dateFrom, dateTo);
  const backfillCount = await backfillShipVia(dateFrom, dateTo);

  console.log(`Sync complete. Invoices: ${invoiceCount}, ShipVia backfilled: ${backfillCount}`);
  return { invoiceCount, backfillCount, dateFrom, dateTo };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });

  EdgeRuntime.waitUntil(
    runSync().catch(err => console.error('Sync failed:', err))
  );

  const dateFrom = getDateFrom();
  const dateTo   = getDateTo();

  return new Response(
    JSON.stringify({ success: true, message: `Sync started for ${dateFrom} to ${dateTo}. Check logs for progress.` }),
    { headers: { 'Content-Type': 'application/json', ...CORS } }
  );
});
