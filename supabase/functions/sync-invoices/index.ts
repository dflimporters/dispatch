// Supabase Edge Function: sync-invoices
// Pulls SO-Invoice headers from Acumatica and upserts into public.invoices
// One row per invoice — companion to invoiced_items (line items)
//
// FIX (2026-07-01): corrected 4 field names that don't exist on Acumatica's
// SO-Invoice OData entity — these were causing Acumatica to reject the whole
// request with a 500 on every single run since deployment:
//   CreatedDateTime      -> CreatedOn
//   LastModifiedDateTime -> LastModifiedOn
//   FinancialPeriod      -> PostPeriod
//   CurrencyID           -> Currency
//
// 2026-10-24: window widened from 3 days back / 1 day ahead to 7 / 7. Invoices dated past tomorrow
// (e.g. Monday's run prepared on Friday) were never pulled in, so Load Sheets couldn't find them.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const ACUMATICA_BASE_URL   = 'https://dflimporters.acumatica.com';
const ACUMATICA_USERNAME   = Deno.env.get('ACUMATICA_USERNAME')!;
const ACUMATICA_PASSWORD   = Deno.env.get('ACUMATICA_PASSWORD')!;
const SUPABASE_URL         = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const INVOICE_ENDPOINT = `${ACUMATICA_BASE_URL}/odata/dfl%20importers/SO-Invoice`;
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

// Coerce any value to a trimmed string or null
function t(val: any): string | null {
  if (val == null) return null;
  const s = String(val).trim();
  return s === '' ? null : s;
}

// Coerce to a float or null
function n(val: any): number | null {
  if (val == null) return null;
  const f = parseFloat(String(val));
  return isNaN(f) ? null : f;
}

// Rolling window dates
function getDateFrom(daysBack = DAYS_BACK): string {
  const d = new Date();
  d.setDate(d.getDate() - daysBack);
  return d.toISOString().split('T')[0] + 'T00:00:00';
}

function getDateTo(): string {
  const d = new Date();
  d.setDate(d.getDate() + DAYS_AHEAD);
  return d.toISOString().split('T')[0] + 'T23:59:59';
}

async function fetchPage(
  filter: string,
  select: string,
  skip: number
): Promise<any[]> {
  const url = new URL(INVOICE_ENDPOINT);
  url.searchParams.set('$filter', filter);
  url.searchParams.set('$select', select);
  url.searchParams.set('$top',    String(BATCH_SIZE));
  url.searchParams.set('$skip',   String(skip));
  url.searchParams.set('$format', 'json');

  console.log(`Fetching SO-Invoice skip=${skip}`);

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

async function syncInvoices(dateFrom: string, dateTo: string): Promise<number> {
  let skip = 0, total = 0;

  // Pull all fields we want — using CORRECTED field names that actually exist
  // on PX.Data.SOInvoice (verified 2026-07-01 against live metadata)
  const SELECT = [
    'ReferenceNbr',
    'OrderNbr',
    'CustomerID',
    'CustomerName',
    'Status',
    'Date',
    'CreatedOn',
    'LastModifiedOn',
    'Amount',
    'TaxTotal',
    'ShipVia',
    'ShipViaDescription',
    'Branch',
    'PostPeriod',
    'Currency',
    'Description',
  ].join(',');

  while (true) {
    const rows = await fetchPage(
      `Type eq 'Invoice' and Date ge datetime'${dateFrom}' and Date le datetime'${dateTo}'`,
      SELECT,
      skip
    );

    if (rows.length === 0) break;

    const transformed = rows
      .map(r => ({
        reference_number:   t(r.ReferenceNbr),
        order_number:       t(r.OrderNbr),
        customer_id:        t(r.CustomerID),
        customer_name:      t(r.CustomerName),
        status:             t(r.Status),
        invoice_date:       r.Date ? r.Date.split('T')[0] : null,
        created_date:       r.CreatedOn ?? null,
        last_modified_date: r.LastModifiedOn ?? null,
        invoice_amount:     n(r.Amount),
        tax_amount:         n(r.TaxTotal),
        ship_via:           t(r.ShipVia),
        ship_via_description: t(r.ShipViaDescription),
        branch:             t(r.Branch),
        financial_period:   t(r.PostPeriod),
        currency_id:        t(r.Currency),
        description:        t(r.Description),
        synced_at:          new Date().toISOString(),
      }))
      .filter(r => r.reference_number != null);

    const { error } = await supabase
      .from('invoices')
      .upsert(transformed, { onConflict: 'reference_number', ignoreDuplicates: false });

    if (error) throw new Error(`Upsert error: ${error.message}`);

    total += rows.length;
    console.log(`Upserted ${total} invoice headers so far`);

    if (rows.length < BATCH_SIZE) break;
    skip += BATCH_SIZE;
  }

  return total;
}

async function runSync(daysBack?: number) {
  const dateFrom = getDateFrom(daysBack ?? DAYS_BACK);
  const dateTo   = getDateTo();
  console.log(`sync-invoices: ${dateFrom} → ${dateTo}`);

  const count = await syncInvoices(dateFrom, dateTo);

  console.log(`sync-invoices complete. Total upserted: ${count}`);
  return { count, dateFrom, dateTo };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });

  // Optional: pass ?days=30 to widen the window (useful for testing / manual backfill)
  const url      = new URL(req.url);
  const daysBack = parseInt(url.searchParams.get('days') ?? String(DAYS_BACK), 10);

  EdgeRuntime.waitUntil(
    runSync(daysBack).catch(err => console.error('sync-invoices failed:', err))
  );

  const dateFrom = getDateFrom(daysBack);
  const dateTo   = getDateTo();

  return new Response(
    JSON.stringify({
      success: true,
      message: `sync-invoices started for ${dateFrom} → ${dateTo}. Check Edge Function logs for progress.`,
    }),
    { headers: { 'Content-Type': 'application/json', ...CORS } }
  );
});
