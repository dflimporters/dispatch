// Shared by batcher.html and clerk.html: Supabase client, Microsoft sign-in,
// role check, header, the TEST/live switch, and the load maths.
//
// Everything a page changes goes through the dispatch_* database functions
// (role and status checks live there) or the dispatch-acu edge function (the
// only thing that talks to Acumatica). See supabase/ in this repo.

const SUPABASE_URL = 'https://hzagwndglwhcepsirafi.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_5rAinfDT1K9kwEQnqYwlOA_-C5tk_6h';
// Named `sb`, never `supabase`: the CDN script defines `supabase` as the library.
const sb = supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, flowType: 'pkce', storageKey: 'dfl-dispatch-auth' },
});

const MAX_DROPS = 10;
const JM_OFFSET_H = -5;          // Jamaica, no DST
const AM_CUTOFF_UTC_H = 13;      // 8am Jamaica: on hand before this goes on the AM run
const POOL_DAYS_BACK = 14;       // older open shipments still show, flagged
const STALE_MIN = 15;
// The Test / Live switch is shown. Each device remembers its choice; Test is
// the default until someone picks Live. Live writes still need the server
// switches (DISPATCH_LIVE_WRITEBACK, DISPATCH_LIVE_CHECKER) in dispatch-acu.
const LIVE_ENABLED = true;

const ROLE_NAMES = { batcher: 'Logistics Coordinator', clerk: 'Trucker Liaison', picker: 'Picker', checker: 'Checker' };

const D = { env: 'test', me: null, truckTypes: [], codes: [], acuStatus: null,
  lines: new Map(),       // shipment_nbr -> its line items (shipment_lines)
  openShips: new Set(),   // shipments expanded to show their items
  openDetails: new Set(), // <details data-keep=key> the user has opened
};

// Pages redraw by replacing HTML, which would close every <details>. Ones
// marked with keep(key) remember being open across redraws.
function keep(key) { return `data-keep="${esc(key)}" ${D.openDetails.has(key) ? 'open' : ''}`; }
document.addEventListener('toggle', e => {
  const k = e.target && e.target.dataset && e.target.dataset.keep;
  if (k) e.target.open ? D.openDetails.add(k) : D.openDetails.delete(k);
}, true);

// ------------------------------------------------------------------
// Small helpers
// ------------------------------------------------------------------
function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
}
function fmt(n) { return Math.round(n || 0).toLocaleString('en-US'); }
function vol(r) { return Number(r && r.shipped_volume) || 0; }
function qty(r) { return Number(r && r.shipped_qty) || 0; }
function val(r) { return Number(r && r.shipment_value) || 0; }
// J$ with thousands; 1.25M style past a million so it fits a column.
function money(n) {
  n = Number(n) || 0;
  if (Math.abs(n) >= 1e6) return 'J$' + (n / 1e6).toFixed(n >= 1e7 ? 1 : 2) + 'M';
  return 'J$' + Math.round(n).toLocaleString('en-US');
}
function isBatch(v) { return !!v && /^BATCH/i.test(v); }
function jmDate(offsetDays) {
  const d = new Date(Date.now() + JM_OFFSET_H * 3600e3);
  d.setUTCDate(d.getUTCDate() + offsetDays);
  return d.toISOString().split('T')[0];
}
function addDays(iso, n) {
  const d = new Date(iso + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().split('T')[0];
}
function niceDate(iso) {
  const [y, m, d] = iso.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString('en-GB', { weekday:'short', day:'numeric', month:'short', timeZone:'UTC' });
}
function stamp(iso) {
  return iso ? new Date(iso).toLocaleString('en-GB', { day:'numeric', month:'short', hour:'2-digit', minute:'2-digit' }) : '';
}
function plural(n, word) { return `${n} ${word}${n === 1 ? '' : 's'}`; }
function toast(msg, bad) {
  const el = document.createElement('div');
  el.className = 'toast' + (bad ? ' bad' : '');
  el.textContent = msg;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), bad ? 6000 : 2500);
}
function errMsg(e) { return (e && (e.message || e.error_description || e.error)) || String(e); }

// Small inline icons (stroke = currentColor).
const ICON = {
  filter: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 5h18l-7 8v5l-4 2v-7z"/></svg>',
  sun:    '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>',
  moon:   '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/></svg>',
  chev:   '<svg class="ico chev" viewBox="0 0 24 24" aria-hidden="true"><path d="M9 6l6 6-6 6"/></svg>',
};
function waveTag(w, title) {
  return `<span class="tag ${w === 'PM' ? 'pm' : 'am'}" title="${esc(title || (w === 'PM' ? 'Evening run' : 'Morning run'))}">${w === 'PM' ? ICON.moon : ICON.sun}${w}</span>`;
}
// All / AM / PM filter, remembered per device and page.
function waveFilterHtml(cur) {
  return `<div class="seg wavef" role="group" aria-label="Filter by run"><span class="seg-ico" title="Filter">${ICON.filter}</span>${
    [['all', 'All', ''], ['AM', 'AM', ICON.sun], ['PM', 'PM', ICON.moon]].map(([k, l, i]) =>
      `<button data-wave="${k}" class="${cur === k ? 'on' : ''}">${i}${l}</button>`).join('')}</div>`;
}
function loadWaveFilter(page) {
  try { const w = localStorage.getItem('dispatch-wave-' + page); return ['all', 'AM', 'PM'].includes(w) ? w : 'all'; }
  catch (e) { return 'all'; }
}
function saveWaveFilter(page, w) { try { localStorage.setItem('dispatch-wave-' + page, w); } catch (e) {} }

// ------------------------------------------------------------------
// Environment: 'test' pairs with shipments_test + the Acumatica TEST
// tenant; 'live' with shipments + production. Remembered per device.
// ------------------------------------------------------------------
function loadEnv() {
  if (!LIVE_ENABLED) { D.env = 'test'; return; }
  try { const e = localStorage.getItem('dispatch-env'); if (e === 'live' || e === 'test') D.env = e; } catch (e) {}
}
function setEnv(e) {
  D.env = e;
  try { localStorage.setItem('dispatch-env', e); } catch (x) {}
}
function shipTable() { return D.env === 'test' ? 'shipments_test' : 'shipments'; }

// ------------------------------------------------------------------
// Sign-in gate + header
// ------------------------------------------------------------------
function gate(html) {
  document.getElementById('app').innerHTML = `<div class="gate">${html}</div>`;
}

async function signIn() {
  const redirectTo = location.origin + location.pathname;
  const { error } = await sb.auth.signInWithOAuth({ provider: 'azure', options: { scopes: 'email openid profile', redirectTo } });
  if (error) toast("Couldn't start sign-in: " + errMsg(error), true);
}

async function signOut() {
  await sb.auth.signOut();
  location.reload();
}

// Signs in, checks the role, draws the header, then hands over to the page.
async function startPage({ page, role, title, onReady, onEnvChange }) {
  loadEnv();
  const { data: { session } } = await sb.auth.getSession();
  if (!session) {
    gate(`<h2>DFL Dispatch · ${esc(title)}</h2>
      <p>Sign in with your DFL Microsoft account.</p>
      <button class="btn primary" id="signin">Sign in with Microsoft</button>`);
    document.getElementById('signin').onclick = signIn;
    return;
  }
  const { data: me, error } = await sb.rpc('dispatch_me');
  if (error) { gate(`<h2>Something went wrong</h2><p>${esc(errMsg(error))}</p><button class="btn" onclick="signOut()">Sign out</button>`); return; }
  D.me = me;
  if (!me.roles.includes(role)) {
    const roleName = ROLE_NAMES[role] || role;
    gate(`<h2>No ${esc(roleName)} access</h2>
      <p>You're signed in as <b>${esc(session.user.email)}</b>, but this account doesn't have the ${esc(roleName)} role for dispatch. Ask Joel to add it.</p>
      <button class="btn" onclick="signOut()">Sign out</button>`);
    return;
  }

  // index.html is just a landing page that links to these, so it isn't in the nav.
  const links = [['batcher.html', 'Coordinator', 'batcher'], ['transfers.html', 'Transfers', 'batcher', 'transfers'],
                 ['clerk.html', 'Trucker Liaison', 'clerk'], ['picking.html', 'Picking', 'picker'], ['checker.html', 'Checker', 'checker']]
    .filter(([, , r]) => me.roles.includes(r))
    .map(([href, label, r, key]) => `<a href="${href}" class="${(key || r) === page ? 'on' : ''}">${label}</a>`).join('');
  document.getElementById('app').innerHTML = `
    <div class="hdr">
      <div class="brand"><h1>${esc(title)}</h1><nav>${links}</nav></div>
      <div class="who"><span>${esc(me.name || session.user.email)}</span><button class="btn small" id="signout">Sign out</button></div>
    </div>
    <div id="envbar"></div>
    <div id="main"><div class="empty">Loading…</div></div>`;
  document.getElementById('signout').onclick = signOut;
  renderEnvBar(onEnvChange);

  try { await Promise.all([loadTruckTypes(), loadCodes()]); }
  catch (e) { document.getElementById('main').innerHTML = `<div class="err">Couldn't load setup data. ${esc(errMsg(e))}</div>`; return; }
  onReady();
}

function renderEnvBar(onEnvChange) {
  const el = document.getElementById('envbar');
  const test = D.env === 'test';
  el.innerHTML = `<div class="envbar ${test ? 'test' : 'live'}">
    ${test
      ? '<span><b>TEST</b> · Shipments from the Acumatica test system. Writing a load changes test only.</span>'
      : '<span><b>LIVE</b> · Production shipments. Anything written goes to live Acumatica (once switched on there).</span>'}
    ${LIVE_ENABLED ? `<div class="seg"><button data-env="test" class="${test ? 'on' : ''}">Test</button><button data-env="live" class="${test ? '' : 'on'}">Live</button></div>` : ''}
  </div>`;
  const seg = el.querySelector('.seg');
  if (seg) seg.onclick = e => {
    const b = e.target.closest('button[data-env]');
    if (!b || b.dataset.env === D.env) return;
    setEnv(b.dataset.env);
    renderEnvBar(onEnvChange);
    onEnvChange();
  };
}

// ------------------------------------------------------------------
// Data
// ------------------------------------------------------------------
async function loadTruckTypes() {
  const { data, error } = await sb.from('truck_types').select('name, capacity_volume').eq('active', true).order('capacity_volume');
  if (error) throw error;
  D.truckTypes = (data || []).map(t => ({ ...t, capacity_volume: Number(t.capacity_volume) }));
}
async function loadCodes() {
  const { data, error } = await sb.from('ship_via_codes').select('ship_via, description').order('ship_via').range(0, 999);
  if (error) throw error;
  D.codes = (data || []).filter(c => !isBatch(c.ship_via));
}
function codeInfo(v) { return D.codes.find(c => c.ship_via === v) || null; }

// ship_via_codes is synced from production. TEST is an older copy, so in Test
// mode the clerk only gets long-standing truckers seen on TEST shipments.
const TEST_TRUCKERS = ['CJACKTRK01', 'DWRIGHTTRK02', 'DWRIGHTTRK03', 'LEONANDERSONTRK',
  'LINVALWALFORD5T', 'ROBBIETRK01', 'ROBERTLEETRK01', 'RSIMMS TRK1'];
function shipViaChoices() {
  return D.env === 'test' ? D.codes.filter(c => TEST_TRUCKERS.includes(c.ship_via)) : D.codes;
}
function truck(name) { return D.truckTypes.find(t => t.name === name) || null; }

const SHIP_COLS = 'shipment_nbr,status,shipment_date,customer_id,customer_name,shipping_zone,ship_via,shipped_volume,shipped_qty,shipment_value,created_on,order_nbr,operation,order_type,synced_at';

// Rows by shipment number, in chunks (PostgREST URLs have a length limit).
async function shipmentsByNbr(nbrs) {
  const out = [];
  for (let i = 0; i < nbrs.length; i += 150) {
    const { data, error } = await sb.from(shipTable()).select(SHIP_COLS).in('shipment_nbr', nbrs.slice(i, i + 150));
    if (error) throw error;
    out.push(...(data || []));
  }
  return out;
}

// Loads for a date with their shipments, shipment rows and history.
async function fetchLoads(date) {
  const { data: loads, error } = await sb.from('loads').select('*').eq('env', D.env).eq('load_date', date).order('wave').order('seq');
  if (error) throw error;
  const ids = (loads || []).map(l => l.id);
  let ls = [], evs = [];
  if (ids.length) {
    const [a, b] = await Promise.all([
      sb.from('load_shipments').select('*').in('load_id', ids),
      sb.from('load_events').select('*').in('load_id', ids).order('created_at', { ascending: false }),
    ]);
    if (a.error) throw a.error;
    if (b.error) throw b.error;
    ls = a.data || []; evs = b.data || [];
  }
  const rows = ls.length ? await shipmentsByNbr(ls.map(x => x.shipment_nbr)) : [];
  const byNbr = new Map(rows.map(r => [r.shipment_nbr, r]));
  return (loads || []).map(l => {
    const mine = ls.filter(x => x.load_id === l.id).map(x => ({ ...x, row: byNbr.get(x.shipment_nbr) || null }));
    return { ...l, ships: mine, events: evs.filter(e => e.load_id === l.id), ...loadStats(mine.map(x => x.row).filter(Boolean)) };
  });
}

async function lastSync() {
  const { data } = await sb.from(shipTable()).select('synced_at').order('synced_at', { ascending: false }).limit(1);
  return data && data[0] ? new Date(data[0].synced_at) : null;
}
function syncText(when) {
  if (!when) return '<span class="sync">Not synced yet</span>';
  const mins = Math.round((Date.now() - when.getTime()) / 60000);
  const stale = D.env === 'live' && mins > STALE_MIN;
  return `<span class="sync ${stale ? 'stale' : ''}">${D.env === 'test' ? 'TEST data pulled' : 'Synced from Acumatica'} ${mins < 1 ? 'just now' : mins < 120 ? mins + ' min ago' : stamp(when.toISOString())}</span>`;
}

// Call the dispatch-acu edge function as the signed-in user.
async function callAcu(action, body) {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) throw new Error('Signed out; reload and sign in again');
  const res = await fetch(`${SUPABASE_URL}/functions/v1/dispatch-acu`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${session.access_token}` },
    body: JSON.stringify({ action, ...(body || {}) }),
  });
  let json = null;
  try { json = await res.json(); } catch (e) {}
  if (!res.ok && !(json && 'ok' in json)) throw new Error(`dispatch-acu ${res.status}`);
  return json;
}

// ------------------------------------------------------------------
// Shipment line items (expandable shipment rows)
// ------------------------------------------------------------------
// Loads the items for these shipments into D.lines (in chunks; a day is a few
// hundred shipments, ~10 lines each). Shipments with no lines get [].
async function loadLines(nbrs) {
  const want = [...new Set(nbrs)];
  const got = new Map(want.map(n => [n, []]));
  for (let i = 0; i < want.length; i += 100) {
    const { data, error } = await sb.from('shipment_lines')
      .select('shipment_nbr,line_nbr,inventory_id,description,uom,ordered_qty,shipped_qty,line_value,location_id')
      .eq('env', D.env).in('shipment_nbr', want.slice(i, i + 100)).order('line_nbr').range(0, 4999);
    if (error) throw error;
    (data || []).forEach(l => got.get(l.shipment_nbr).push(l));
  }
  got.forEach((v, k) => D.lines.set(k, v));
}
// Lines that went out short of what was ordered (stock not available).
function shortLines(nbr) {
  return (D.lines.get(nbr) || []).filter(l => l.ordered_qty != null && Number(l.shipped_qty) < Number(l.ordered_qty));
}
// The chevron that opens a shipment, plus a "short" tag when lines went out short.
function shipToggle(nbr) {
  const open = D.openShips.has(nbr);
  const short = shortLines(nbr).length;
  return `<button class="stog ${open ? 'open' : ''}" data-ship-toggle="${esc(nbr)}" title="${open ? 'Hide' : 'Show'} items" aria-expanded="${open}">${ICON.chev}</button>` +
    `${esc(nbr)}${short ? ` <span class="tag old" title="${plural(short, 'line')} shipped short of the order">${short} short</span>` : ''}`;
}
// The expanded row under a shipment: its items.
function linesRow(nbr, colspan) {
  if (!D.openShips.has(nbr)) return '';
  const lines = D.lines.get(nbr);
  const body = !lines ? '<div class="muted">Loading items…</div>'
    : !lines.length ? `<div class="muted">${D.env === 'live' ? "Item detail isn't synced for live shipments yet." : 'No items found for this shipment. Pull fresh TEST data.'}</div>`
    : `<table class="items"><thead><tr><th>Item</th><th>Description</th><th>UOM</th><th class="r">Ordered</th><th class="r">Shipped</th><th class="r">Value</th><th class="hide-m">Location</th></tr></thead>
      <tbody>${lines.map(l => {
        const short = l.ordered_qty != null && Number(l.shipped_qty) < Number(l.ordered_qty);
        return `<tr class="${short ? 'short' : ''}"><td class="num">${esc(l.inventory_id || '')}</td><td>${esc(l.description || '')}</td><td>${esc(l.uom || '')}</td>
          <td class="r num">${fmt(l.ordered_qty)}</td><td class="r num">${fmt(l.shipped_qty)}${short ? ` <span class="tag old">−${fmt(Number(l.ordered_qty) - Number(l.shipped_qty))}</span>` : ''}</td>
          <td class="r num">${l.line_value == null ? '<span class="muted">—</span>' : money(l.line_value)}</td><td class="hide-m">${esc(l.location_id || '')}</td></tr>`;
      }).join('')}</tbody></table>`;
  return `<tr class="lines-row"><td colspan="${colspan}">${body}</td></tr>`;
}
// Opening a shipment: toggle it, fetch its items if we don't have them, redraw.
function onShipToggle(rerender) {
  document.getElementById('app').addEventListener('click', async e => {
    const b = e.target.closest('[data-ship-toggle]');
    if (!b) return;
    e.stopPropagation();
    const nbr = b.dataset.shipToggle;
    D.openShips.has(nbr) ? D.openShips.delete(nbr) : D.openShips.add(nbr);
    rerender();
    if (D.openShips.has(nbr) && !D.lines.has(nbr)) {
      try { await loadLines([nbr]); } catch (err) { D.lines.set(nbr, []); toast(errMsg(err), true); }
      rerender();
    }
  }, true);
}

// ------------------------------------------------------------------
// Load maths
// ------------------------------------------------------------------
function loadStats(rows) {
  const customers = new Set(rows.map(r => r.customer_id || r.shipment_nbr));
  const zones = [...new Set(rows.map(r => r.shipping_zone || 'No zone'))].sort();
  return {
    vol: rows.reduce((s, r) => s + vol(r), 0), qty: rows.reduce((s, r) => s + qty(r), 0),
    value: rows.reduce((s, r) => s + val(r), 0), drops: customers.size, zones, count: rows.length,
  };
}

// AM if it was on hand before the 8am run on the load date (or is from an
// earlier date), otherwise PM. Only a suggestion; the batcher sets the wave.
function suggestWave(r, loadDate) {
  if (r.shipment_date && r.shipment_date < loadDate) return 'AM';
  if (!r.created_on) return 'AM';
  const [y, m, d] = loadDate.split('-').map(Number);
  return new Date(r.created_on) < new Date(Date.UTC(y, m - 1, d, AM_CUTOFF_UTC_H)) ? 'AM' : 'PM';
}

// Fewest trucks carrying `volume` and `drops` stops (max MAX_DROPS each);
// among equal counts, the smallest total capacity. Same rule as the Overview.
// Returns [{ type, count }] largest first, or null.
function bestFit(volume, drops) {
  const types = D.truckTypes;
  if (!types.length) return null;
  const maxCap = types[types.length - 1].capacity_volume;
  const minK = Math.max(1, Math.ceil(drops / MAX_DROPS), Math.ceil(volume / maxCap));
  for (let k = minK; k <= minK + 20; k++) {
    let best = null;
    const counts = new Array(types.length).fill(0);
    (function walk(i, left, cap) {
      if (i === types.length - 1) {
        const total = cap + left * types[i].capacity_volume;
        if (total >= volume && (!best || total < best.total)) { counts[i] = left; best = { total, counts: counts.slice() }; }
        counts[i] = 0;
        return;
      }
      for (let c = 0; c <= left; c++) { counts[i] = c; walk(i + 1, left - c, cap + c * types[i].capacity_volume); }
      counts[i] = 0;
    })(0, k, 0);
    if (best) return best.counts.map((count, i) => ({ type: types[i], count })).filter(x => x.count > 0).reverse();
  }
  return null;
}
function fitLabel(fit) {
  return fit ? fit.map(x => (x.count > 1 ? x.count + ' × ' : '') + x.type.name).join(' + ') : '—';
}
// Smallest truck that holds `volume`, else the biggest.
function smallestTruckFor(volume) {
  return D.truckTypes.find(t => t.capacity_volume >= volume) || D.truckTypes[D.truckTypes.length - 1] || null;
}

// Suggested loads for a set of free shipments: per wave, per zone, the
// best-fit truck mix, then stops (one per customer, largest first) placed
// into the truck with the most room left that still has a drop free.
// Each truck is then shrunk to the smallest type that holds what it got.
function suggestLoads(rows, loadDate) {
  const out = [];
  const byKey = new Map();
  for (const r of rows) {
    const k = suggestWave(r, loadDate) + '|' + (r.shipping_zone || 'No zone');
    if (!byKey.has(k)) byKey.set(k, []);
    byKey.get(k).push(r);
  }
  for (const [k, zrows] of [...byKey.entries()].sort()) {
    const [wave, zone] = k.split('|');
    const stops = new Map();
    for (const r of zrows) {
      const c = r.customer_id || r.shipment_nbr;
      if (!stops.has(c)) stops.set(c, { vol: 0, rows: [] });
      const s = stops.get(c); s.vol += vol(r); s.rows.push(r);
    }
    const stopList = [...stops.values()].sort((a, b) => b.vol - a.vol);
    const total = stopList.reduce((s, x) => s + x.vol, 0);
    const fit = bestFit(total, stopList.length) || [];
    const trucks = fit.flatMap(f => Array.from({ length: f.count }, () => ({ cap: f.type.capacity_volume, vol: 0, drops: 0, rows: [] })));
    if (!trucks.length) trucks.push({ cap: Infinity, vol: 0, drops: 0, rows: [] });
    for (const s of stopList) {
      const open = trucks.filter(t => t.drops < MAX_DROPS);
      const pool = open.length ? open : trucks;
      const t = pool.reduce((a, b) => (b.cap - b.vol) > (a.cap - a.vol) ? b : a);
      t.vol += s.vol; t.drops++; t.rows.push(...s.rows);
    }
    for (const t of trucks.filter(t => t.rows.length)) {
      const tt = smallestTruckFor(t.vol);
      out.push({ wave, zone, truck_type: tt ? tt.name : null, vol: t.vol, drops: t.drops, nbrs: t.rows.map(r => r.shipment_nbr) });
    }
  }
  return out;
}

function capBar(l) {
  const t = truck(l.truck_type);
  if (!t) return `<span class="muted">${fmt(l.vol)} volume · no truck picked</span>`;
  const pct = t.capacity_volume ? (l.vol / t.capacity_volume) * 100 : 0;
  const cls = pct > 100 ? 'over' : pct < 50 ? 'low' : '';
  return `<span class="cap"><span class="bar"><span class="${cls}" style="width:${Math.min(100, pct)}%"></span></span><span class="num">${fmt(l.vol)} / ${fmt(t.capacity_volume)}</span></span>`;
}
function loadWarnings(l) {
  const w = [];
  const t = truck(l.truck_type);
  if (l.drops > MAX_DROPS) w.push(`${l.drops} drops, over the ${MAX_DROPS}-drop limit.`);
  if (t && l.vol > t.capacity_volume) w.push(`${fmt(l.vol)} volume won't fit a ${esc(t.name)} (${fmt(t.capacity_volume)}).`);
  const missing = l.ships.filter(s => !s.row).length;
  if (missing) w.push(`${plural(missing, 'shipment')} no longer in the ${D.env === 'test' ? 'TEST' : 'Acumatica'} data.`);
  return w.length ? `<div class="warnbox">${w.join(' ')}</div>` : '';
}
function statusPill(s) {
  return {
    draft:     '<span class="pill done">Draft · with coordinator</span>',
    ready:     '<span class="pill info">With liaison · needs trucker</span>',
    confirmed: '<span class="pill warn">Trucker confirmed · not written</span>',
    writing:   '<span class="pill warn">Writing to Acumatica…</span>',
    done:      '<span class="pill ok">Trucker locked in</span>',
    partial:   '<span class="pill bad">Partly written</span>',
  }[s] || esc(s);
}
function resultPill(s) {
  if (!s.result) return '';
  return { applied: '<span class="pill ok">Applied</span>', refused: '<span class="pill warn">Refused</span>', failed: '<span class="pill bad">Failed</span>' }[s.result];
}
function eventList(evs, key) {
  if (!evs.length) return '';
  const label = e => ({ create:'Created', edit:'Edited', move:'Shipments', send:'Sent to liaison', pull_back:'Pulled back', return:'Sent back to coordinator',
    call: e.outcome || 'Call', confirm:'Trucker confirmed', unconfirm:'Confirmation undone', writeback:'Acumatica', unstick:'Marked stuck', delete:'Deleted',
    pick_done:'Picked', pick_reopen:'Pick reopened', check_save:'Checked', check_confirm:'Confirmed in Acumatica' }[e.kind] || e.kind);
  return `<details ${key ? keep(key) : ''}><summary>History (${evs.length})</summary><ul class="evs">${evs.map(e => `<li><b>${esc(label(e))}</b>${e.ship_via ? ' · ' + esc(e.ship_via) : ''}${e.contractor ? ' · ' + esc(e.contractor) : ''}${e.note ? ' — ' + esc(e.note) : ''}
    <span style="float:right">${esc(e.actor_name || '')}, ${esc(stamp(e.created_at))}</span></li>`).join('')}</ul></details>`;
}
