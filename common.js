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

const ROLE_NAMES = { batcher: 'Logistics Coordinator', clerk: 'Trucker Liaison', picker: 'Picker', checker: 'Checker',
  supervisor: 'Supervisor', manager: 'Operations Manager', security: 'Security' };

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
// opts: { action: { label, fn }, ms }. Errors stay up longer; an action (Retry / Undo) longer still.
function toast(msg, bad, opts) {
  opts = opts || {};
  let host = document.getElementById('toasts');
  if (!host) { host = document.createElement('div'); host.id = 'toasts'; host.setAttribute('role', 'status'); host.setAttribute('aria-live', 'polite'); document.body.appendChild(host); }
  const el = document.createElement('div');
  el.className = 'toast' + (bad ? ' bad' : '');
  const t = document.createElement('span'); t.textContent = msg; el.appendChild(t);
  const close = () => el.remove();
  if (opts.action) {
    const b = document.createElement('button'); b.className = 'toast-act'; b.textContent = opts.action.label;
    b.onclick = () => { close(); opts.action.fn(); };
    el.appendChild(b);
  }
  host.appendChild(el);
  while (host.children.length > 3) host.firstChild.remove();
  setTimeout(close, opts.ms || (opts.action ? 8000 : bad ? 6000 : 2500));
}
// Raw errors in words a picker can act on. Messages the database raises on purpose
// (business rules) pass through; transport and auth failures are rewritten.
function errMsg(e) {
  const m = String((e && (e.message || e.error_description || e.error)) || e || 'Something went wrong');
  if (/failed to fetch|networkerror|load failed|network request failed/i.test(m) || (typeof navigator !== 'undefined' && navigator.onLine === false)) return "Can't reach the server. Check the wifi and try again.";
  if (/jwt|refresh token|not authenticated/i.test(m) && /expired|invalid|missing|not found|not authenticated/i.test(m)) return 'Your sign-in expired. Reload the page and sign in again.';
  if (/^dispatch-acu \d+$/.test(m)) return `Acumatica didn't answer (${m.split(' ')[1]}). Try again in a moment.`;
  if (/^5\d\d\b|gateway|timed? ?out/i.test(m)) return 'The server is busy. Try again in a moment.';
  return m;
}

// ------------------------------------------------------------------
// States: skeleton loaders, empty states, errors with retry, "updated" and "saved" chips
// ------------------------------------------------------------------
function skeleton(n) {
  return `<div class="skel-wrap" aria-busy="true" aria-label="Loading">${Array.from({ length: n || 3 }, () =>
    '<div class="skel-card"><div class="skel w40"></div><div class="skel w70"></div><div class="skel w55"></div></div>').join('')}</div>`;
}
// What's empty and what to do next. next = { label, id } renders a button with data-next=id.
function emptyState(msg, hint, next) {
  return `<div class="empty-state"><div class="es-ico">${ICON.inbox}</div><div class="es-msg">${msg}</div>${hint ? `<div class="es-hint">${hint}</div>` : ''}${next ? `<button class="btn primary" data-next="${esc(next.id)}">${esc(next.label)}</button>` : ''}</div>`;
}
// A failed load, in words, with a button that runs the page's refresh() (or reloads).
function errBox(e, what) {
  console.error('[load]', e);
  return `<div class="err-state" role="alert"><div class="es-msg">${esc(what || "Couldn't load this page")}</div><div class="es-hint">${esc(errMsg(e))}</div><button class="btn primary" data-retry-load>Try again</button></div>`;
}
document.addEventListener('click', e => {
  if (!e.target.closest || !e.target.closest('[data-retry-load]')) return;
  const m = document.getElementById('main'); if (m) m.innerHTML = skeleton(3);
  if (typeof refresh === 'function') refresh(); else location.reload();
});

// "Live" / "Updated 40s ago" chip in the header, amber when the data is stale.
// markFresh() is called whenever data is (re)read.
const FRESH = { at: 0 };
function markFresh() { FRESH.at = Date.now(); paintFresh(); }
function paintFresh() {
  const el = document.getElementById('freshchip'); if (!el || !FRESH.at) return;
  const secs = Math.round((Date.now() - FRESH.at) / 1000), stale = secs > 120;
  el.className = 'fresh' + (stale ? ' stale' : '');
  el.title = 'Last refreshed ' + new Date(FRESH.at).toLocaleTimeString('en-GB');
  el.innerHTML = `<i></i>${stale ? 'Updated ' + Math.round(secs / 60) + ' min ago' : secs < 10 ? 'Just updated' : 'Updated ' + secs + 's ago'}`;
}
setInterval(paintFresh, 5000);
// Brief "Saved" tick beside the chip after a write goes through.
function flashSaved() {
  const el = document.getElementById('savedchip'); if (!el) return;
  el.classList.remove('on'); void el.offsetWidth; el.classList.add('on');
}

// Haptic + optional sound on pick / check actions. Haptic on by default (phones only);
// sound is off until someone turns it on; both remembered per device.
const FB = { sound: false, haptic: true };
try { FB.sound = localStorage.getItem('dispatch-sound') === '1'; FB.haptic = localStorage.getItem('dispatch-haptic') !== '0'; } catch (e) {}
let _ac = null;
function feedback(kind) {   // 'ok' | 'bad'
  try { if (FB.haptic && navigator.vibrate) navigator.vibrate(kind === 'bad' ? [60, 40, 60] : 25); } catch (e) {}
  if (!FB.sound) return;
  try {
    _ac = _ac || new (window.AudioContext || window.webkitAudioContext)();
    const o = _ac.createOscillator(), g = _ac.createGain();
    o.frequency.value = kind === 'bad' ? 220 : 880; g.gain.value = .08;
    o.connect(g); g.connect(_ac.destination); o.start(); o.stop(_ac.currentTime + (kind === 'bad' ? .25 : .09));
  } catch (e) {}
}
function setSound(on) { FB.sound = on; try { localStorage.setItem('dispatch-sound', on ? '1' : '0'); } catch (e) {} }

// Small inline icons (stroke = currentColor).
const ICON = {
  filter: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 5h18l-7 8v5l-4 2v-7z"/></svg>',
  sun:    '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>',
  moon:   '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/></svg>',
  inbox:  '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 13l3-8h12l3 8v6H3zM3 13h5l1 3h6l1-3h5"/></svg>',
  speaker:'<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9v6h4l5 4V5L8 9zM16.5 8.5a5 5 0 0 1 0 7"/></svg>',
  grid:   '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z"/></svg>',
  chev:   '<svg class="ico chev" viewBox="0 0 24 24" aria-hidden="true"><path d="M9 6l6 6-6 6"/></svg>',
};
function waveTag(w, title) {
  if (w === 'ACU') return '<span class="tag acu" title="Ship Via was set in Acumatica; these loads have no AM/PM run">ACU</span>';
  return `<span class="tag ${w === 'PM' ? 'pm' : 'am'}" title="${esc(title || (w === 'PM' ? 'Evening run' : 'Morning run'))}">${w === 'PM' ? ICON.moon : ICON.sun}${w}</span>`;
}
// Extra tags for loads that didn't come from the clerk, or are left over from an earlier day.
function loadOriginTags(l) {
  return (l.source === 'acumatica' ? '<span class="tag" title="The Ship Via was set directly in Acumatica">From Acumatica</span> ' : '') +
    (l.source === 'invoice' ? '<span class="tag" title="Built from invoices; picked outside the portal">Picked outside portal</span> ' : '') +
    (l.closed_at ? `<span class="tag" title="${esc(l.closed_reason || '')}">Closed</span> ` : '') +
    (l.carried ? `<span class="tag old" title="Not finished on its own day">Carried over from ${esc(niceDate(l.load_date))}</span> ` : '');
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
const LMS_NAME = 'Logistics Management System';
const MS_LOGO = '<svg class="ms-logo" viewBox="0 0 21 21" aria-hidden="true"><path fill="#f25022" d="M1 1h9v9H1z"/><path fill="#7fba00" d="M11 1h9v9h-9z"/><path fill="#00a4ef" d="M1 11h9v9H1z"/><path fill="#ffb900" d="M11 11h9v9h-9z"/></svg>';

// Full-screen card: DFL logo above the system name, then the message.
function gate(html) {
  document.body.classList.add('is-gate');
  const old = document.getElementById('chrome'); if (old) old.remove();
  document.getElementById('app').innerHTML = `<div class="gate-wrap"><div class="gate">
    <div class="gbrand"><img src="assets/dfl-logo-color.png" alt="DFL Importers"><span>${LMS_NAME}</span></div>
    ${html}</div></div>`;
}

function initials(name) {
  const p = String(name || '?').split(/[\s@.]+/).filter(Boolean);
  return ((p[0] || '?')[0] + (p.length > 1 ? p[1][0] : '')).toUpperCase();
}

// Top bar (logo over system name), tab strip, page title. Drawn into #chrome,
// a sibling above .page, so it spans the full width. `nav` is [[href, label, on]].
function drawChrome({ title, nav, name, roles }) {
  let el = document.getElementById('chrome');
  if (!el) { el = document.createElement('div'); el.id = 'chrome'; el.className = 'hdr'; document.body.insertBefore(el, document.body.firstChild); }
  document.body.classList.remove('is-gate');
  const tabs = nav && nav.length ? `<div class="lms-tabs"><nav class="lms-tabs-in" aria-label="Pages">${
    nav.map(([href, label, on]) => `<a href="${href}" class="${on ? 'on' : ''}"${on ? ' aria-current="page"' : ''}>${esc(label)}</a>`).join('')}</nav></div>` : '';
  const crumb = title ? `<div class="crumb"><a href="index.html">${LMS_NAME}</a> / ${esc(title)}</div>` : '';
  el.innerHTML = `
    <div class="lms-top"><div class="lms-top-in">
      <a class="lms-brand" href="index.html" title="${LMS_NAME}"><img src="assets/dfl-logo-white.png" alt="DFL Importers"><span>${LMS_NAME}</span></a>
      <div class="lms-who"><a class="home" href="index.html?all=1" title="All my pages" aria-label="All my pages">${ICON.grid}</a><button class="snd${FB.sound ? ' on' : ''}" id="sndbtn" title="Sound on pick and check" aria-label="Sound feedback" aria-pressed="${FB.sound}">${ICON.speaker}</button><div class="av">${esc(initials(name))}</div><div class="nm"><b>${esc(name)}</b>${roles && roles.length ? `<span>${esc(roles.map(r => ROLE_NAMES[r] || r).join(' · '))}</span>` : ''}</div><button class="btn small" id="signout">Sign out</button></div>
    </div></div>
    ${tabs}
    ${title ? `<div class="lms-title"><div>${crumb}<h1>${esc(title)}</h1></div><div class="chips-r"><span class="saved" id="savedchip" aria-live="polite">✓ Saved</span><span class="fresh" id="freshchip"></span></div></div>` : ''}`;
  if (title) document.title = title + ' — ' + LMS_NAME;
  paintFresh();
  const snd = document.getElementById('sndbtn');
  snd.onclick = () => { setSound(!FB.sound); snd.classList.toggle('on', FB.sound); snd.setAttribute('aria-pressed', FB.sound); toast(FB.sound ? 'Sound on' : 'Sound off'); if (FB.sound) feedback('ok'); };
  document.getElementById('signout').onclick = signOut;
  // On a phone the strip scrolls sideways; keep the current page's tab in view.
  const on = el.querySelector('.lms-tabs a.on'), strip = el.querySelector('.lms-tabs-in');
  if (on && strip) strip.scrollLeft = on.offsetLeft - (strip.clientWidth - on.offsetWidth) / 2;
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
    gate(`<h2>${esc(title)}</h2>
      <p>Sign in with your DFL Microsoft account.</p>
      <button class="btn primary ms" id="signin">${MS_LOGO}Sign in with Microsoft</button>`);
    document.getElementById('signin').onclick = signIn;
    return;
  }
  const { data: me, error } = await sb.rpc('dispatch_me');
  if (error) { gate(`<h2>Something went wrong</h2><p>${esc(errMsg(error))}</p><button class="btn" onclick="signOut()">Sign out</button>`); return; }
  D.me = me;
  const needs = [].concat(role);   // a page can allow more than one role
  if (!needs.some(r => me.roles.includes(r))) {
    const roleName = needs.map(r => ROLE_NAMES[r] || r).join(' or ');
    gate(`<h2>No ${esc(roleName)} access</h2>
      <p>You're signed in as <b>${esc(session.user.email)}</b>, but this account doesn't have the ${esc(roleName)} role for dispatch. Ask Joel to add it.</p>
      <button class="btn" onclick="signOut()">Sign out</button>`);
    return;
  }

  // index.html is just a landing page that links to these, so it isn't in the nav.
  const links = [['batcher.html', 'Coordinator', 'batcher'], ['salesorders.html', 'Sales Orders', 'batcher', 'salesorders'], ['transfers.html', 'Transfers', 'batcher', 'transfers'],
                 ['clerk.html', 'Trucker Liaison', 'clerk'], ['picking.html', 'Picking', 'picker'], ['checker.html', 'Checker', 'checker'],
                 ['tower.html', 'Control Tower', ['batcher', 'clerk', 'supervisor', 'manager'], 'tower'],
                 ['loadsheet.html', 'Load sheets', ['batcher', 'clerk', 'supervisor', 'manager'], 'loadsheet'],
                 ['returns.html', 'Returns', ['batcher', 'clerk', 'supervisor', 'manager'], 'returns'],
                 ['security.html', 'Security check', ['security', 'supervisor', 'manager'], 'security'],
                 ['contacts.html', 'Contacts', ['supervisor', 'manager'], 'contacts'],
                 ['invoicing.html', 'Invoicing', 'supervisor'], ['dashboard.html', 'Dashboard', ['manager', 'supervisor'], 'dashboard']]
    .filter(([, , r]) => [].concat(r).some(x => me.roles.includes(x)))
    .map(([href, label, r, key]) => [href, label, (key || r) === page]);
  drawChrome({ title, nav: links, name: me.name || session.user.email, roles: me.roles });
  document.getElementById('app').innerHTML = `
    <div id="envbar"></div>
    <div id="main">${skeleton(3)}</div>`;
  renderEnvBar(onEnvChange);

  try { await Promise.all([loadTruckTypes(), loadCodes()]); }
  catch (e) { document.getElementById('main').innerHTML = errBox(e, "Couldn't load setup data"); return; }
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
  // Most active truckers over the last year first (dispatch_ship_via_ranked).
  const { data, error } = await sb.rpc('dispatch_ship_via_ranked');
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
  const chunks = [];
  for (let i = 0; i < nbrs.length; i += 150) chunks.push(nbrs.slice(i, i + 150));
  const res = await Promise.all(chunks.map(c => sb.from(shipTable()).select(SHIP_COLS).in('shipment_nbr', c)));
  return res.flatMap(r => { if (r.error) throw r.error; return r.data || []; });
}

// Loads for a date with their shipments, shipment rows and history.
// opts.carry: when `date` is today or earlier, also include unconfirmed loads from the
// previous 7 days (l.carried = true), so a load not finished by midnight doesn't vanish.
async function fetchLoads(date, opts) {
  const carry = opts && opts.carry && date <= jmDate(0);
  const from = new Date(Date.parse(date + 'T00:00:00Z') - 7 * 86400e3).toISOString().split('T')[0];
  const [cur, old] = await Promise.all([
    sb.from('loads').select('*').eq('env', D.env).eq('load_date', date).order('wave').order('seq'),
    carry ? sb.from('loads').select('*').eq('env', D.env).gte('load_date', from).lt('load_date', date)
      .in('status', ['done', 'partial']).or('check_status.is.null,check_status.neq.confirmed')
      .order('load_date').order('wave').order('seq') : Promise.resolve({ data: [] }),
  ]);
  if (cur.error) throw cur.error;
  if (old.error) throw old.error;
  const loads = (old.data || []).map(l => ({ ...l, carried: true })).concat(cur.data || []);
  const ids = loads.map(l => l.id);
  let ls = [], evs = [];
  if (ids.length) {
    // History is only drawn on a load's own screen; the picker doesn't need it.
    const [a, b] = await Promise.all([
      sb.from('load_shipments').select('*').in('load_id', ids),
      opts && opts.events === false ? { data: [] } : sb.from('load_events').select('*').in('load_id', ids).order('created_at', { ascending: false }),
    ]);
    if (a.error) throw a.error;
    if (b.error) throw b.error;
    ls = a.data || []; evs = b.data || [];
  }
  const rows = ls.length ? await shipmentsByNbr(ls.map(x => x.shipment_nbr)) : [];
  const byNbr = new Map(rows.map(r => [r.shipment_nbr, r]));
  markFresh();
  return (loads || []).map(l => {
    const mine = ls.filter(x => x.load_id === l.id).map(x => ({ ...x, row: byNbr.get(x.shipment_nbr) || null }));
    return { ...l, ships: mine, events: evs.filter(e => e.load_id === l.id), ...loadStats(mine.map(x => x.row).filter(Boolean)) };
  });
}

// ------------------------------------------------------------------
// Pickup / donation / promotion customers (dispatch_customer_kinds: PROMOTION class plus a
// hand-kept list). Shipments on a PICKUP* ship via count as pickup whatever the customer.
// If the lookup fails the pages still work; only the ship-via rule applies.
// ------------------------------------------------------------------
const KINDS = { pickup: 'Pickup', donation: 'Donation', promotion: 'Promotion' };
const _kinds = { map: new Map(), at: 0 };
async function loadKinds() {
  if (Date.now() - _kinds.at < 5 * 60e3) return;
  try {
    const { data, error } = await sb.rpc('dispatch_customer_kinds');
    if (error) throw error;
    _kinds.map = new Map((data || []).map(r => [r.customer_id, r.kind]));
    _kinds.at = Date.now();
  } catch (e) { console.warn('[kinds]', e); _kinds.at = Date.now() - 4 * 60e3; }
}
// Kind of a customer id / shipment row ({customer_id, ship_via}), or null for a normal delivery.
function kindOf(r) {
  if (!r) return null;
  return _kinds.map.get(r.customer_id) || (/^PICKUP/i.test(r.ship_via || '') ? 'pickup' : null);
}
function kindTag(k) {
  return k ? `<span class="tag kind kind-${k}" title="${KINDS[k]} customer: handle ahead of normal deliveries">${KINDS[k]}</span> ` : '';
}
// Distinct kinds among a load's shipments, in a stable order.
function loadKinds_(l) {
  const s = new Set((l.ships || []).map(x => kindOf(x.row)).filter(Boolean));
  if (/^PICKUP/i.test(l.ship_via || '')) s.add('pickup');
  return Object.keys(KINDS).filter(k => s.has(k));
}
function loadKindTags(l) { return loadKinds_(l).map(kindTag).join(''); }
const isSpecialLoad = l => loadKinds_(l).length > 0;
// Delivery | Pickup/Donation/Promotion tab switch. counts = {delivery, special}.
function kindTabsHtml(cur, counts) {
  return `<div class="seg kindtabs" role="tablist" aria-label="Order type">
    <button role="tab" data-ktab="delivery" class="${cur === 'delivery' ? 'on' : ''}">Delivery · ${counts.delivery}</button>
    <button role="tab" data-ktab="special" class="${cur === 'special' ? 'on' : ''}">Pickup / Donation / Promotion · ${counts.special}</button></div>`;
}
function loadKindTab() { try { return localStorage.getItem('dispatch-kindtab') === 'special' ? 'special' : 'delivery'; } catch (e) { return 'delivery'; } }
function saveKindTab(t) { try { localStorage.setItem('dispatch-kindtab', t); } catch (e) {} }

// Search box on the picker / checker lists: every word has to appear in the load's number,
// ship via, trucker, truck, zones, or any of its shipments' customer, zone or number.
function loadMatches(l, q) {
  const words = String(q || '').toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return true;
  if (!l._hay) {
    l._hay = [l.load_nbr, l.ship_via, l.contractor, l.truck_type, (l.zones || []).join(' '),
      ...l.ships.map(s => [s.shipment_nbr, s.row && s.row.customer_name, s.row && s.row.customer_id, s.row && s.row.shipping_zone].join(' '))
    ].join(' ').toLowerCase();
  }
  return words.every(w => l._hay.includes(w));
}
function searchBox(q) {
  return `<input type="search" id="q" class="searchbox" value="${esc(q)}" placeholder="Search ship via, zone or customer" aria-label="Search loads" autocomplete="off">`;
}
// Re-draws after a keystroke without losing the caret in the search box.
function keepSearchFocus(draw) {
  const had = document.activeElement && document.activeElement.id === 'q';
  draw();
  if (!had) return;
  const el = document.getElementById('q');
  if (el) { el.focus(); const n = el.value.length; try { el.setSelectionRange(n, n); } catch (e) {} }
}

// Keeps a page current: re-reads when another screen saves (realtime on the pick / check
// tables), when the tab comes back to the front, and on a slow timer as the safety net.
// skip() says the user is typing; the refresh is held until they leave the box.
function keepFresh(refresh, skip, tables) {
  let timer = null, held = false, last = 0;
  const run = async () => {
    timer = null;
    if (document.hidden) return;
    if (skip()) { held = true; return; }
    held = false; last = Date.now();
    await refresh(); markFresh();
  };
  const soon = ms => { if (!timer) timer = setTimeout(run, ms); };
  try {
    let ch = sb.channel('fresh-' + location.pathname);
    (tables || []).forEach(t => { ch = ch.on('postgres_changes', { event: '*', schema: 'public', table: t }, () => soon(300)); });
    ch.subscribe();
  } catch (e) { console.warn('[realtime]', e); }
  document.addEventListener('visibilitychange', () => { if (!document.hidden) soon(50); });
  document.addEventListener('focusout', () => { if (held) soon(400); });
  setInterval(() => { if (Date.now() - last > 9000) soon(0); }, 10000);
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

// Pull production's shipments and their line items now, rather than waiting for
// the 5-minute cron: sync-shipments (headers, ~10s), then dispatch-acu
// sync_live_lines (items for Open / On Hold shipments). Both are the same jobs
// cron runs. Returns { shipments, lines } counts; throws if the shipment pull fails.
async function syncLiveNow() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) throw new Error('Signed out; reload and sign in again');
  const res = await fetch(`${SUPABASE_URL}/functions/v1/sync-shipments`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: SUPABASE_PUBLISHABLE_KEY, Authorization: `Bearer ${session.access_token}` },
    body: '{}',
  });
  let j = null;
  try { j = await res.json(); } catch (e) {}
  if (!res.ok || !(j && j.success)) throw new Error((j && j.error) || `Shipment pull failed (${res.status})`);
  let lines = null;
  try { const r = await callAcu('sync_live_lines'); lines = r.ok ? r.lines : null; if (!r.ok) toast("Shipments refreshed, but items didn't: " + (r.error || ''), true); }
  catch (e) { toast("Shipments refreshed, but items didn't: " + errMsg(e), true); }
  return { shipments: j.upserted, lines };
}

// ------------------------------------------------------------------
// Shipment line items (expandable shipment rows)
// ------------------------------------------------------------------
// Loads the items for these shipments into D.lines (in chunks; a day is a few
// hundred shipments, ~10 lines each). Shipments with no lines get [].
async function loadLines(nbrs) {
  const want = [...new Set(nbrs)];
  const got = new Map(want.map(n => [n, []]));
  const chunks = [];
  for (let i = 0; i < want.length; i += 100) chunks.push(want.slice(i, i + 100));
  const res = await Promise.all(chunks.map(c => sb.from('shipment_lines')
    .select('shipment_nbr,line_nbr,inventory_id,description,uom,ordered_qty,shipped_qty,line_value,location_id')
    .eq('env', D.env).in('shipment_nbr', c).order('line_nbr').range(0, 4999)));
  res.forEach(r => { if (r.error) throw r.error; (r.data || []).forEach(l => got.get(l.shipment_nbr).push(l)); });
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
// A load waiting in the Acumatica queue (dispatch-acu drains it in the background).
function writeQueued(l) { return ['confirmed', 'partial'].includes(l.status) && !!l.write_requested_at; }
function confirmQueued(l) { return ['checking', 'partial'].includes(l.check_status) && !!l.confirm_requested_at; }

// "Writing 3 of 6" with a bar. done = shipments through so far.
function progressBox(label, done, total, note) {
  const pct = total ? Math.round(100 * done / total) : 0;
  return `<div class="prog"><div class="prog-top"><b>${esc(label)}</b><span>${done} of ${total}</span></div>
    <div class="prog-bar ${done ? '' : 'wait'}"><i style="width:${pct}%"></i></div>${note ? `<div class="prog-note">${esc(note)}</div>` : ''}</div>`;
}

function resultPill(s) {
  if (!s.result) return '';
  return { applied: '<span class="pill ok">Applied</span>', refused: '<span class="pill warn">Refused</span>', failed: '<span class="pill bad">Failed</span>', skipped: '<span class="pill done">Skipped</span>' }[s.result];
}
function eventList(evs, key) {
  if (!evs.length) return '';
  const label = e => ({ create:'Created', edit:'Edited', move:'Shipments', send:'Sent to liaison', pull_back:'Pulled back', return:'Sent back to coordinator',
    call: e.outcome || 'Call', confirm:'Trucker confirmed', unconfirm:'Confirmation undone', writeback:'Acumatica', unstick:'Marked stuck', delete:'Deleted',
    pick_done:'Picked', pick_reopen:'Pick reopened', check_save:'Split saved', check_done:'Check finished', check_reopen:'Check reopened', check_confirm:'Confirmed in Acumatica' }[e.kind] || e.kind);
  return `<details ${key ? keep(key) : ''}><summary>History (${evs.length})</summary><ul class="evs">${evs.map(e => `<li><b>${esc(label(e))}</b>${e.ship_via ? ' · ' + esc(e.ship_via) : ''}${e.contractor ? ' · ' + esc(e.contractor) : ''}${e.note ? ' — ' + esc(e.note) : ''}
    <span style="float:right">${esc(e.actor_name || '')}, ${esc(stamp(e.created_at))}</span></li>`).join('')}</ul></details>`;
}
