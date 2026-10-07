// acu-probe: READ-ONLY check of the Acumatica 2026 R1 sandbox before any
// dispatch code is pointed at it. Signs in, lists the endpoints the instance
// offers, reads a few open shipments (with lines and the LOADNBR field)
// through both Default/24.200.001 (what dispatch-acu uses today) and
// Default/25.200.001 (2026 R1's newest), checks SalesInvoice access, and
// signs out. Nothing is written.
//
// The sandbox allows 1 concurrent API request and 50 per minute, so every
// call runs one after another with a pause between them.
//
// POST with header x-test-token = SHIPVIA_TEST_TOKEN. Uses the same API login
// as TEST (ACU_SHIPVIA_USERNAME / ACU_SHIPVIA_PASSWORD).

const BASE   = 'https://dflimporters-sandbox-26-1.acumatica.com';
const TENANT = 'DFL Importers';
const VERSIONS = ['24.200.001', '25.200.001'];
const GAP_MS = 1500;   // ~40 calls/min at most, under the sandbox's 50

const USERNAME = Deno.env.get('ACU_SHIPVIA_USERNAME') ?? '';
const PASSWORD = Deno.env.get('ACU_SHIPVIA_PASSWORD') ?? '';
const TOKEN    = Deno.env.get('SHIPVIA_TEST_TOKEN') ?? '';

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body, null, 2), { status, headers: { 'Content-Type': 'application/json' } });
}
function sameToken(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
function v(field: any): any {
  const x = field?.value;
  return typeof x === 'string' ? (x.trim() || null) : (x ?? null);
}

let cookie = '';
let calls = 0;
async function call(method: string, url: string, body?: unknown) {
  if (calls++) await sleep(GAP_MS);
  const t = Date.now();
  const res = await fetch(url.startsWith('http') ? url : `${BASE}${url}`, {
    method,
    headers: { Cookie: cookie, Accept: 'application/json', 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let data: any = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text.slice(0, 500); }
  return { status: res.status, ok: res.ok, ms: Date.now() - t, data, setCookie: res.headers.getSetCookie() };
}

async function probe() {
  const out: Record<string, unknown> = { base: BASE, tenant: TENANT };

  const login = await call('POST', '/entity/auth/login', { name: USERNAME, password: PASSWORD, tenant: TENANT });
  out.login = { status: login.status, ms: login.ms, error: login.ok ? undefined : login.data };
  if (!login.ok) return out;
  cookie = login.setCookie.map(c => c.split(';')[0]).join('; ');

  try {
    const ep = await call('GET', '/entity');
    out.endpoints = ep.ok
      ? (ep.data?.endpoints ?? ep.data)?.map?.((e: any) => `${e.name}/${e.version}`) ?? ep.data
      : { status: ep.status, error: ep.data };

    for (const ver of VERSIONS) {
      const r: Record<string, unknown> = {};
      const q = `$top=3&$filter=Status eq 'Open'&$select=ShipmentNbr,Status,ShipVia,ShipmentDate,CustomerID`
        + `&$expand=Details&$custom=Document.AttributeLOADNBR`;
      const s = await call('GET', `/entity/Default/${ver}/Shipment?${q}`);
      r.shipments = s.ok
        ? (s.data as any[]).map(x => ({
            nbr: v(x.ShipmentNbr), status: v(x.Status), ship_via: v(x.ShipVia), customer: v(x.CustomerID),
            loadnbr: v(x.custom?.Document?.AttributeLOADNBR), lines: x.Details?.length ?? 0,
            line_fields: x.Details?.[0] ? Object.keys(x.Details[0]).filter(k => !['id', 'rowNumber', 'note', 'custom', '_links'].includes(k)) : [],
          }))
        : { status: s.status, error: s.data };
      r.shipment_ms = s.ms;

      const inv = await call('GET', `/entity/Default/${ver}/SalesInvoice?$top=1&$select=ReferenceNbr,Type,Status`);
      r.sales_invoice = inv.ok ? { ok: true, sample: (inv.data as any[])[0] ? v((inv.data as any[])[0].ReferenceNbr) : null } : { status: inv.status, error: inv.data };
      out[`Default/${ver}`] = r;
    }

    // Is a Report endpoint already published? (needed for invoice PDFs)
    const rep = await call('GET', '/entity/Report/0001/$adHocSchema');
    out.report_endpoint = { status: rep.status };
  } finally {
    const lo = await call('POST', '/entity/auth/logout');
    out.logout = lo.status;
  }
  out.calls = calls;
  return out;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405);
  if (!TOKEN || !sameToken(req.headers.get('x-test-token') ?? '', TOKEN)) return json({ ok: false, error: 'bad or missing x-test-token' }, 401);
  try { return json({ ok: true, ...(await probe()) }); }
  catch (e) { return json({ ok: false, error: String(e) }, 500); }
});
