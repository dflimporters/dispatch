// OMS driver app, step 4: scan, review, claim, resume, the route (order, On the way /
// Arrived), the delivery checklist with reason codes, proof-of-delivery photos, failed
// stops, all through an offline queue. No accounts. The phone holds a device id and,
// once it has claimed a load, that load's token. See index.html and the lm_* migrations
// in supabase/migrations/.
'use strict';

const SUPABASE_URL = 'https://hzagwndglwhcepsirafi.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_5rAinfDT1K9kwEQnqYwlOA_-C5tk_6h';
const UPLOAD_URL = SUPABASE_URL + '/functions/v1/lm-upload';
// Named `sb`: the CDN script defines `supabase` as the library. No session is kept; every call is anon.
const sb = supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
});

const CODE_RE = /^[0-9A-HJKMNP-TV-Z]{8}$/;
const GPS_WAIT_MS = 3000;          // a press waits at most this long for a position
const SYNC_EVERY_MS = 30 * 1000;   // retry the queues while the app is open
const REFRESH_EVERY_MS = 60 * 1000;
const PHOTO_MAX_PX = 1600;         // longest side of a stored photo
const PHOTO_QUALITY = 0.8;
const S = {
  peek: null, code: null, session: null, data: null, queue: [],
  offline: false, stream: null, scanning: false, timer: null, busy: false,
  syncing: false, pressing: false, editing: false, draft: [], notice: null, gpsDenied: false, warmed: false,
  screen: null,                      // null = the route; { kind: 'check' | 'abort', stop: id } or { kind: 'abortload' } or { kind: 'qr' }
  form: { receiver: {}, edit: null, editing: null, refuseAll: null, abortReason: '', abortNote: '', loadReason: '', loadNote: '' },
  waiting: new Set(),                // ids of photos still on this phone
  uploading: false,
};

// ------------------------------------------------------------------
// Small helpers
// ------------------------------------------------------------------
function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
const LS = {
  get(k) { try { return JSON.parse(localStorage.getItem(k)); } catch (e) { return null; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} },
  del(k) { try { localStorage.removeItem(k); } catch (e) {} },
};
function uuid() {
  if (crypto.randomUUID) return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map(x => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
function deviceId() {
  let d = LS.get('lm.device');
  if (!d) { d = uuid(); LS.set('lm.device', d); }
  return d;
}
// Same clean-up as the database: drop spaces and dashes, upper-case, O->0, I and L->1.
function normCode(s) {
  return String(s || '').replace(/[^0-9A-Za-z]/g, '').toUpperCase().replace(/O/g, '0').replace(/[IL]/g, '1');
}
// A scanned QR holds either the bare code or a link ending in ?c=CODE.
function extractCode(text) {
  let t = String(text || '').trim();
  try { const c = new URL(t).searchParams.get('c'); if (c) t = c; } catch (e) {}
  const n = normCode(t);
  return CODE_RE.test(n) ? n : null;
}
function timeOf(iso) { return iso ? new Date(iso).toLocaleTimeString('en-JM', { hour: 'numeric', minute: '2-digit' }) : ''; }
function dateOf(iso) { return iso ? new Date(iso + 'T00:00:00').toLocaleDateString('en-JM', { weekday: 'short', day: 'numeric', month: 'short' }) : ''; }
function fmt(n) { return Math.round(Number(n) || 0).toLocaleString('en-US'); }
function num(n) { n = Number(n) || 0; return Number.isInteger(n) ? String(n) : String(Math.round(n * 100) / 100); }
function plural(n, w) { return `${n} ${w}${n === 1 ? '' : 's'}`; }
const el = id => document.getElementById(id);
function show(html) { el('app').innerHTML = html; window.scrollTo(0, 0); lastScreenKey = null; }
function banner(n) { return n ? `<div class="banner ${n.kind || 'info'}">${n.html}</div>` : ''; }

async function rpc(name, args) {
  const { data, error } = await sb.rpc(name, args);
  if (error) {
    const e = new Error(error.message || String(error));
    e.code = error.code;
    e.network = !error.code;               // no SQLSTATE: the request never reached the database
    throw e;
  }
  return data;
}

function setOffline(v) { S.offline = v; el('net').hidden = !v; }
window.addEventListener('online', () => { setOffline(false); if (S.session) { refreshLoad(); uploadPhotos(); } });
window.addEventListener('offline', () => setOffline(true));

// ------------------------------------------------------------------
// Photos on the phone (IndexedDB, with a memory fallback). A photo stays here until the
// upload succeeds, so a dead zone or a closed app never loses one.
// ------------------------------------------------------------------
const PH = {
  db: null, mem: new Map(),
  open() {
    if (this.db) return Promise.resolve(this.db);
    return new Promise((resolve, reject) => {
      if (!window.indexedDB) { reject(new Error('no indexedDB')); return; }
      const r = indexedDB.open('lm-driver', 1);
      r.onupgradeneeded = () => r.result.createObjectStore('photos', { keyPath: 'id' });
      r.onsuccess = () => { this.db = r.result; resolve(r.result); };
      r.onerror = () => reject(r.error);
    });
  },
  async run(mode, fn) {
    try {
      const db = await this.open();
      return await new Promise((resolve, reject) => {
        const t = db.transaction('photos', mode);
        const req = fn(t.objectStore('photos'));
        t.oncomplete = () => resolve(req ? req.result : undefined);
        t.onerror = () => reject(t.error);
        t.onabort = () => reject(t.error);
      });
    } catch (e) { return undefined; }
  },
  async put(rec) {
    this.mem.set(rec.id, rec);                  // memory copy too, in case IndexedDB is unavailable
    await this.run('readwrite', st => st.put(rec));
  },
  async all() {
    const stored = await this.run('readonly', st => st.getAll());
    const map = new Map(this.mem);
    (stored || []).forEach(r => map.set(r.id, r));
    return [...map.values()];
  },
  async del(id) { this.mem.delete(id); await this.run('readwrite', st => st.delete(id)); },
  async clear() { this.mem.clear(); await this.run('readwrite', st => st.clear()); },
};
async function countPhotos() {
  const all = await PH.all();
  S.waiting = new Set(all.map(p => p.id));
}

// Shrink a phone photo: longest side PHOTO_MAX_PX, JPEG. A few hundred KB instead of several MB.
async function shrink(file) {
  let bmp;
  try { bmp = await createImageBitmap(file, { imageOrientation: 'from-image' }); }
  catch (e) { bmp = await createImageBitmap(file); }
  const scale = Math.min(1, PHOTO_MAX_PX / Math.max(bmp.width, bmp.height));
  const c = document.createElement('canvas');
  c.width = Math.max(1, Math.round(bmp.width * scale)); c.height = Math.max(1, Math.round(bmp.height * scale));
  c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
  if (bmp.close) bmp.close();
  return new Promise((resolve, reject) => c.toBlob(b => b ? resolve(b) : reject(new Error('Could not read the photo')), 'image/jpeg', PHOTO_QUALITY));
}

// Take a photo with the phone's camera and register it. kind: pod | damage | abort.
function takePhoto(kind, stopId, lineId) {
  const inp = document.createElement('input');
  inp.type = 'file'; inp.accept = 'image/*'; inp.setAttribute('capture', 'environment');
  inp.onchange = async () => {
    const f = inp.files && inp.files[0];
    if (!f) return;
    try {
      const blob = await shrink(f);
      const d = view();
      const stop = d.stops.find(s => s.id === stopId);
      const line = lineId ? (stop.lines || []).find(l => l.id === lineId) : null;
      const nbrs = kind === 'pod' ? (stop.invoices || []).map(i => i.shipment_nbr) : line ? [line.shipment_nbr] : (stop.invoices || []).map(i => i.shipment_nbr);
      const id = uuid();
      await PH.put({ id, blob, stopId, kind, createdAt: Date.now() });
      S.waiting.add(id);
      await press('file', stopId, { file_id: id, kind, shipment_nbrs: nbrs, line_id: lineId || null, taken_at: new Date().toISOString() }, false);
    } catch (e) {
      S.notice = { kind: 'bad', html: "<b>Couldn't use that photo.</b> Try again." };
      renderLoad();
    }
  };
  inp.click();
}

// Send photos whose registration has already reached the office.
async function uploadPhotos() {
  if (S.uploading || !S.session) return;
  S.uploading = true;
  try {
    const registering = new Set(S.queue.filter(e => e.kind === 'file').map(e => e.payload.file_id));
    for (const p of await PH.all()) {
      if (registering.has(p.id)) continue;
      try {
        const res = await fetch(UPLOAD_URL, {
          method: 'POST',
          headers: { 'x-lm-token': S.session.token, 'x-lm-file': p.id, 'Content-Type': 'image/jpeg', apikey: SUPABASE_PUBLISHABLE_KEY },
          body: p.blob,
        });
        setOffline(false);
        if (res.ok) { await PH.del(p.id); }
        else if (res.status === 401) { await dropLoad(); return; }
        // anything else (not registered yet, a hiccup): leave it on the phone and try again later
      } catch (e) { setOffline(true); break; }
    }
  } finally {
    S.uploading = false;
    await countPhotos();
    if (S.session) rerender();
  }
}

// ------------------------------------------------------------------
// Scan screen
// ------------------------------------------------------------------
function renderScan(notice) {
  stopScan();
  S.peek = null; S.code = null;
  show(`
    <h1>Scan your load</h1>
    <p class="lead">Point the camera at the QR code on your load sheet.</p>
    ${banner(notice)}
    <div class="viewfinder" id="vf"><video id="cam" playsinline muted></video><div class="hint" id="camhint">Starting the camera…</div></div>
    <canvas id="grab" hidden></canvas>
    <div class="btns"><button class="btn" data-act="typecode">Type the code instead</button></div>`);
  startScan();
}

async function startScan() {
  const video = el('cam');
  if (!video) return;
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
    el('camhint').textContent = "This phone can't open the camera here. Type the code instead.";
    return;
  }
  try {
    S.stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: 'environment' } }, audio: false });
    video.srcObject = S.stream;
    await video.play();
    el('camhint').textContent = 'Hold steady until it reads';
    S.scanning = true;
    scanTick();
  } catch (e) {
    const hint = el('camhint');
    if (hint) hint.textContent = (e && e.name === 'NotAllowedError')
      ? 'Camera is switched off for this app. Allow it in your phone settings, or type the code.'
      : "Couldn't start the camera. Type the code instead.";
  }
}

function scanTick() {
  if (!S.scanning) return;
  const video = el('cam'), canvas = el('grab');
  if (video && canvas && video.readyState === video.HAVE_ENOUGH_DATA && video.videoWidth) {
    const scale = Math.min(1, 640 / video.videoWidth);
    canvas.width = Math.round(video.videoWidth * scale);
    canvas.height = Math.round(video.videoHeight * scale);
    const ctx = canvas.getContext('2d', { willReadFrequently: true });
    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
    const img = ctx.getImageData(0, 0, canvas.width, canvas.height);
    const hit = jsQR(img.data, canvas.width, canvas.height, { inversionAttempts: 'dontInvert' });
    if (hit) {
      const code = extractCode(hit.data);
      if (code) { if (navigator.vibrate) navigator.vibrate(60); doPeek(code); return; }
    }
  }
  S.timer = setTimeout(scanTick, 130);
}

function stopScan() {
  S.scanning = false;
  clearTimeout(S.timer);
  if (S.stream) { S.stream.getTracks().forEach(t => t.stop()); S.stream = null; }
}

function renderTypeCode(notice) {
  stopScan();
  show(`
    <h1>Type the code</h1>
    <p class="lead">It is the 8 letters and numbers printed under the QR code on your load sheet.</p>
    ${banner(notice)}
    <input class="code" id="codein" maxlength="12" inputmode="text" autocapitalize="characters" autocomplete="off" autocorrect="off" spellcheck="false" placeholder="XXXX-XXXX">
    <div class="btns">
      <button class="btn primary" data-act="codego">Look up this load</button>
      <button class="btn link" data-act="scan">Scan the QR code instead</button>
    </div>`);
  el('codein').focus();
}

// ------------------------------------------------------------------
// Review screen
// ------------------------------------------------------------------
async function doPeek(code) {
  if (S.busy) return;
  S.busy = true;
  stopScan();
  show(`<p class="lead"><span class="spin"></span>Looking up the load…</p>`);
  try {
    S.peek = await rpc('lm_peek', { p_code: code, p_device: deviceId() });
    S.code = code;
    renderReview();
  } catch (e) {
    if (e.network) renderScan({ kind: 'bad', html: "<b>No signal.</b> The app needs a connection to look up a load. Try again when you have signal, or type the code." });
    else if (e.code === 'LM404') renderTypeCode({ kind: 'bad', html: "<b>That code isn't recognised.</b> Check it against your load sheet and try again." });
    else renderScan({ kind: 'bad', html: esc(e.message) });
  } finally { S.busy = false; }
}

function renderReview(notice) {
  const p = S.peek;
  const head = `
    <div class="card">
      <div class="muted">Load number</div>
      <div class="loadnbr">${esc(p.load_nbr)}</div>
      <div class="forwho">Load for ${esc(p.trucker)}<small>${esc(p.ship_via || '')}${p.truck_type ? ' · ' + esc(p.truck_type) : ''}</small></div>
    </div>`;
  const back = `<button class="btn link" data-act="scan">Not this load? Scan again</button>`;

  if (p.state === 'not_ready') {
    show(`<h1>Not ready yet</h1>${head}<div class="banner warn"><b>The checker hasn't confirmed this load yet.</b> Wait for the warehouse to tell you it is ready.</div><div class="btns">${back}</div>`);
    return;
  }
  if (p.state === 'finished') {
    show(`<h1>Finished</h1>${head}<div class="banner info">This load is already finished.</div><div class="btns">${back}</div>`);
    return;
  }

  const heldOther = p.state === 'held' && !p.held_by_this_device;
  const heldHere = p.state === 'held' && p.held_by_this_device;
  const zones = (p.zones || []).map(z => `<span class="tag">${esc(z)}</span>`).join('') || '<span class="muted">none listed</span>';
  const firsts = (p.first_customers || []).map(c => `<div class="kv"><span>${esc(c)}</span></div>`).join('');

  show(`
    <h1>Check your load</h1>
    ${banner(notice)}
    ${head}
    <div class="card">
      <div class="kv"><span>Date</span><b>${esc(dateOf(p.load_date))}${p.wave && p.wave !== 'ACU' ? ' · ' + esc(p.wave) : ''}</b></div>
      <div class="kv"><span>Stops</span><b>${p.stops}</b></div>
      <div class="kv"><span>Invoices</span><b>${p.shipments}</b></div>
      <div class="kv"><span>Items on the truck</span><b>${fmt(p.units)} <span class="muted">(${plural(p.products, 'product')})</span></b></div>
      <div class="kv"><span>Confirmed by checker</span><b>${esc(timeOf(p.checked_at)) || '—'}</b></div>
      <div style="margin-top:8px"><div class="muted" style="margin-bottom:4px">Areas</div>${zones}</div>
      ${firsts ? `<div style="margin-top:10px"><div class="muted" style="margin-bottom:2px">First stops</div>${firsts}</div>` : ''}
    </div>

    ${p.blocked_by ? `<div class="banner bad"><b>You still have ${esc(p.blocked_by)} open.</b> Finish it first, or ask the office.</div>` : ''}
    ${heldOther ? `<div class="banner warn"><b>Already collected by ${esc(p.held_by || 'someone')} on another phone.</b> If you carry on, the load moves to this phone and the office is told.</div>` : ''}
    ${heldHere ? `<div class="banner info">This load is already on this phone. Carry on to open it again.</div>` : ''}
    ${p.soft_mismatch ? `<div class="banner bad"><b>Check this is the right load.</b> This load is for ${esc(p.trucker_key)}. This phone last ran ${esc(p.last_trucker)}.</div>` : ''}

    ${p.can_claim ? `
      <label class="fld">Your name<input class="txt" id="c_name" type="text" autocomplete="name" autocapitalize="words" placeholder="First and last name" value="${esc(LS.get('lm.driver') || '')}"></label>
      <label class="fld">Your phone number<input class="txt" id="c_phone" type="tel" inputmode="tel" autocomplete="tel" placeholder="For example: 876 555 1234" value="${esc(LS.get('lm.phone') || '')}"></label>
      <label class="check"><input type="checkbox" id="c_me"><span><b>Yes, this is my load.</b> I am driving for ${esc(p.trucker)}.</span></label>
      ${p.soft_mismatch ? `<label class="check red"><input type="checkbox" id="c_soft"><span>I know this phone last ran ${esc(p.last_trucker)}. This is my load anyway.</span></label>` : ''}
      ${heldOther ? `<label class="check amber"><input type="checkbox" id="c_take"><span>Move this load to my phone.</span></label>` : ''}
      <div class="btns">
        <button class="btn primary" id="claimbtn" data-act="claim" disabled>${heldHere ? 'Open my load' : 'I have the full load. Take responsibility.'}</button>
        <button class="btn warn" data-act="missing">Something is missing</button>
        ${back}
      </div>
      <div id="missingbox" hidden>
        <h2>What is missing?</h2>
        <textarea class="note" id="missingnote" placeholder="For example: 2 cases of rice, pallet of oil"></textarea>
        <div class="btns"><button class="btn danger" data-act="sendmissing">Tell the office</button></div>
      </div>` : `<div class="btns">${back}</div>`}`);
  wireReview();
}

// The claim button stays off until every box that applies has been ticked.
const phoneOk = v => String(v || '').replace(/[^0-9]/g, '').length >= 7;
function wireReview() {
  const btn = el('claimbtn');
  if (!btn) return;
  const boxes = ['c_me', 'c_soft', 'c_take'].map(el).filter(Boolean);
  const ph = el('c_phone'), nm = el('c_name');
  const sync = () => { btn.disabled = !boxes.every(b => b.checked) || !phoneOk(ph && ph.value) || String((nm && nm.value) || '').trim().length < 2; };
  boxes.forEach(b => b.addEventListener('change', sync));
  if (ph) ph.addEventListener('input', sync);
  if (nm) nm.addEventListener('input', sync);
  sync();
}

async function doClaim() {
  if (S.busy) return;
  const p = S.peek;
  S.busy = true;
  const btn = el('claimbtn'); if (btn) { btn.disabled = true; btn.textContent = 'Taking responsibility…'; }
  const phone = ((el('c_phone') || {}).value || '').trim();
  const driver = ((el('c_name') || {}).value || '').trim().replace(/\s+/g, ' ');
  try {
    const r = await rpc('lm_claim', {
      p_code: S.code, p_device: deviceId(), p_name: driver, p_phone: phone,
      p_override_soft: !!(el('c_soft') && el('c_soft').checked),
      p_takeover: !!(el('c_take') && el('c_take').checked),
    });
    LS.set('lm.phone', phone); LS.set('lm.driver', driver);
    S.session = { token: r.token, code: S.code, load_nbr: p.load_nbr, claimed_at: Date.now() };
    S.data = r.data;
    S.queue = []; S.editing = false; S.warmed = false; S.screen = null; resetForm();
    await PH.clear(); S.waiting = new Set();
    LS.set('lm.session', S.session);
    LS.set('lm.data', S.data);
    LS.set('lm.queue', S.queue);
    S.notice = { kind: 'ok', html: r.kind === 'rescan' ? '<b>Load opened on this phone.</b>' : '<b>You are now responsible for this load.</b>' };
    renderLoad();
  } catch (e) {
    S.busy = false;
    if (e.network) { renderReview({ kind: 'bad', html: '<b>No signal.</b> Your claim did not go through. Try again when you have signal.' }); return; }
    // Something changed since the review (soft check, held by another phone, blocked...): look again and say why.
    try { S.peek = await rpc('lm_peek', { p_code: S.code, p_device: deviceId() }); } catch (x) {}
    renderReview({ kind: 'bad', html: esc(e.message) });
  } finally { S.busy = false; }
}

async function sendMissing() {
  const note = (el('missingnote').value || '').trim();
  if (!note) { el('missingnote').focus(); return; }
  if (S.busy) return;
  S.busy = true;
  try {
    await rpc('lm_report_shortage', { p_code: S.code, p_device: deviceId(), p_note: note });
    show(`<h1>The office has been told</h1>
      <div class="banner ok"><b>Thank you.</b> The office knows something is missing from ${esc(S.peek.load_nbr)}. Wait for the warehouse to sort it out, then scan again.</div>
      <div class="btns"><button class="btn" data-act="scan">Back to scan</button></div>`);
  } catch (e) {
    show(`<h1>Could not send</h1><div class="banner bad">${esc(e.network ? 'No signal. Try again when you have signal.' : e.message)}</div>
      <div class="btns"><button class="btn" data-act="review">Back</button></div>`);
  } finally { S.busy = false; }
}

// ------------------------------------------------------------------
// The load as the phone sees it: the server's copy plus anything still queued
// ------------------------------------------------------------------
const DONE = ['delivered', 'partial', 'failed'];

// What the server will decide for a stop whose lines are all marked.
function outcomeOf(stop) {
  const lines = stop.lines || [];
  const exp = lines.reduce((n, l) => n + Number(l.expected || 0), 0);
  const del = lines.reduce((n, l) => n + Number(l.delivered || 0), 0);
  if (exp > 0 && del === 0) return 'failed';
  return lines.some(l => l.result && l.result !== 'delivered') ? 'partial' : 'delivered';
}

// Mirrors the rules in lm_sync closely enough to show the result at once. The server
// has the final say; its answer replaces this the next time the queue is sent.
function applyLocal(data, queue) {
  const d = JSON.parse(JSON.stringify(data));
  const stops = d.stops || [];
  const byId = id => stops.find(s => s.id === id);
  for (const e of queue) {
    const s = e.stop_id != null ? byId(e.stop_id) : null;
    const p = e.payload || {};
    switch (e.kind) {
      case 'seq_edit': {
        const pend = stops.filter(x => x.status === 'pending');
        const positions = pend.map(x => x.seq).sort((a, b) => a - b);
        const given = (p.order || []).filter(id => pend.some(q => q.id === id));
        const rest = pend.filter(q => !given.includes(q.id)).sort((a, b) => a.seq - b.seq).map(q => q.id);
        given.concat(rest).forEach((id, i) => { byId(id).seq = positions[i]; });
        break;
      }
      case 'on_the_way':
        if (s && s.status === 'pending') { s.status = 'on_the_way'; s.on_the_way_at = e.client_at; if (d.load.status === 'collected') d.load.status = 'delivering'; }
        break;
      case 'cancel_on_the_way':
        if (s && s.status === 'on_the_way') { s.status = 'pending'; s.on_the_way_at = null; }
        break;
      case 'arrived':
        if (s && s.status === 'on_the_way') { s.status = 'arrived'; s.arrived_at = e.client_at; }
        break;
      case 'line_set': {
        const l = s && s.status === 'arrived' ? (s.lines || []).find(x => x.id === p.line_id) : null;
        if (l) {
          l.result = p.result;
          l.delivered = p.result === 'delivered' ? l.expected : p.result === 'refused' ? 0 : Number(p.qty);
          l.reason = p.result === 'delivered' ? null : p.reason_code || null;
          l.note = p.note || null;
        }
        break;
      }
      case 'file':
        if (s && !(s.files || []).some(f => f.id === p.file_id)) {
          (s.files = s.files || []).push({ id: p.file_id, kind: p.kind, line_id: p.line_id || null, shipment_nbrs: p.shipment_nbrs || [], uploaded: false });
        }
        break;
      case 'abort_stop':
        if (s && ['pending', 'on_the_way', 'arrived'].includes(s.status)) { s.status = 'failed'; s.fail_reason = p.reason_code; s.fail_note = p.note || null; s.completed_at = e.client_at; }
        break;
      case 'complete':
        if (s && s.status === 'arrived' && (s.lines || []).every(l => l.result)) {
          s.status = outcomeOf(s); s.completed_at = e.client_at; s.receiver_name = p.receiver_name || null;
          if (s.status === 'failed') { s.fail_reason = s.fail_reason || 'customer_refused'; }
        }
        break;
      case 'abort_load':
        if (['collected', 'delivering'].includes(d.load.status)) {
          stops.filter(x => ['pending', 'on_the_way', 'arrived'].includes(x.status)).forEach(x => {
            const delivered = (x.lines || []).some(l => Number(l.delivered) > 0);
            const left = (x.lines || []).some(l => Number(l.expected) - Number(l.delivered || 0) > 0);
            if (x.status === 'arrived' && delivered) x.status = left ? 'partial' : 'delivered';
            else x.status = 'failed';
            if (x.status !== 'delivered') { x.fail_reason = p.reason_code; x.fail_note = p.note || null; }
            x.completed_at = e.client_at;
          });
          d.load.status = 'completed'; d.load.aborted_at = e.client_at; d.load.abort_reason = p.reason_code; d.load.abort_note = p.note || null;
        }
        break;
    }
  }
  stops.sort((a, b) => a.seq - b.seq);
  if (stops.length && stops.every(s => DONE.includes(s.status))) d.load.status = 'completed';
  return d;
}
const view = () => (S.data ? applyLocal(S.data, S.queue) : null);
const reasonLabel = code => { const r = ((S.data && S.data.reasons) || []).find(x => x.code === code); return r ? r.label : code || ''; };

// Digits for a wa.me link: Jamaican numbers without the country code get 1 (876).
function waNumber(p) {
  const d = String(p || '').replace(/[^0-9]/g, '');
  if (d.length === 7) return '1876' + d;
  if (d.length === 10) return '1' + d;
  return d;
}
const telHref = p => 'tel:' + String(p || '').replace(/[^0-9+]/g, '');

// ------------------------------------------------------------------
// GPS
// ------------------------------------------------------------------
function getPosition() {
  return new Promise(resolve => {
    if (!navigator.geolocation) { resolve(null); return; }
    let settled = false;
    const done = v => { if (!settled) { settled = true; resolve(v); } };
    const t = setTimeout(() => done(null), GPS_WAIT_MS + 200);
    navigator.geolocation.getCurrentPosition(
      p => { clearTimeout(t); S.gpsDenied = false; done({ lat: p.coords.latitude, lng: p.coords.longitude, accuracy: Math.round(p.coords.accuracy) }); },
      err => { clearTimeout(t); if (err && err.code === 1) S.gpsDenied = true; done(null); },
      { enableHighAccuracy: true, timeout: GPS_WAIT_MS, maximumAge: 30000 });
  });
}

// ------------------------------------------------------------------
// Queue: every press is saved on the phone first, then sent when there is signal
// ------------------------------------------------------------------
function saveQueue() { LS.set('lm.queue', S.queue); }
function makeEvent(kind, stopId, payload, pos) {
  return {
    event_uuid: uuid(), kind, stop_id: stopId == null ? null : stopId, client_at: new Date().toISOString(),
    lat: pos ? pos.lat : null, lng: pos ? pos.lng : null, accuracy: pos ? pos.accuracy : null, payload: payload || {},
  };
}
function enqueue(events) {
  S.queue.push(...events);
  saveQueue();
  renderLoad();
  flush();
}

async function press(kind, stopId, payload, withGps, screen) {
  if (S.pressing) return;
  if (['on_the_way', 'arrived', 'complete'].includes(kind) && navigator.vibrate) navigator.vibrate(40);
  S.pressing = true;
  let pos = null;
  if (withGps) {
    document.querySelectorAll('.btn').forEach(b => { b.disabled = true; });
    pos = await getPosition();
  }
  S.pressing = false;
  if (screen) { S.screen = screen; S.form.editing = null; S.form.edit = null; S.form.refuseAll = null; }
  enqueue([makeEvent(kind, stopId, payload, pos)]);
}

// Send the queue in order. The reply carries the server's copy of the load.
async function flush() {
  if (S.syncing || !S.session || !S.queue.length) { if (S.session) uploadPhotos(); return; }
  S.syncing = true;
  try {
    for (;;) {
      const batch = S.queue.slice(0, 50);
      if (!batch.length) break;
      const r = await rpc('lm_sync', { p_token: S.session.token, p_events: batch });
      setOffline(false);
      const sent = new Set(batch.map(e => e.event_uuid));
      S.queue = S.queue.filter(e => !sent.has(e.event_uuid));
      S.data = r.data; LS.set('lm.data', S.data); saveQueue();
      const refused = (r.results || []).filter(x => x.applied === false && !x.replay);
      if (refused.length) {
        S.notice = { kind: 'warn', html: `<b>${plural(refused.length, 'action')} could not be saved:</b> ${esc([...new Set(refused.map(x => x.reason))].join(', '))}. The screen shows the office's copy.` };
      }
    }
  } catch (e) {
    if (e.code === 'LM001') { await dropLoad(); return; }
    if (e.network) setOffline(true);
    else S.notice = { kind: 'bad', html: esc(e.message) };
  } finally { S.syncing = false; }
  if (S.session) { rerender(); uploadPhotos(); }
}

// The office took the load off this phone, or another phone opened it: back to scanning.
async function dropLoad() {
  // A finished load that the office has closed looks the same to the phone as one taken away.
  const finished = !!(S.data && S.data.load && ['completed', 'closed'].includes(S.data.load.status)) && !S.queue.length;
  LS.del('lm.session'); LS.del('lm.data'); LS.del('lm.queue');
  S.session = null; S.data = null; S.queue = []; S.editing = false; S.syncing = false; S.screen = null; resetForm();
  await PH.clear(); S.waiting = new Set();
  renderScan(finished
    ? { kind: 'ok', html: '<b>The office has closed your load.</b> Thank you. Scan your next load when it is ready.' }
    : { kind: 'warn', html: '<b>This load is no longer on your phone.</b> The office took it off, or it was opened on another phone. Scan the right load to carry on.' });
}

// Ask the database for the current copy (sends anything queued first).
async function refreshLoad() {
  if (!S.session || S.busy) return;
  if (S.queue.length) { await flush(); return; }
  if (S.pressing || S.editing) return;
  try {
    const d = await rpc('lm_my_load', { p_token: S.session.token });
    setOffline(false);
    S.data = d; LS.set('lm.data', d);
    rerender();
    uploadPhotos();
  } catch (e) {
    if (e.code === 'LM001') await dropLoad();
    else if (e.network) { setOffline(true); rerender(); }
    else { S.notice = { kind: 'bad', html: esc(e.message) }; rerender(); }
  }
}

// ------------------------------------------------------------------
// Screens for a claimed load
// ------------------------------------------------------------------
function resetForm() { S.form = { receiver: {}, edit: null, editing: null, refuseAll: null, abortReason: '', abortNote: '', loadReason: '', loadNote: '' }; }

// Background refreshes shouldn't wipe what the driver is typing.
function typing() { const a = document.activeElement; return !!a && /^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName) && a.type !== 'checkbox'; }
function rerender() { if (S.session && !typing()) renderLoad(); }

// Redrawing the same screen (ticking an item, a background refresh) keeps the scroll place;
// moving to a different screen starts at the top.
let lastScreenKey = null;
// Banners and status pills appear above what the driver is looking at, so the page is also
// anchored on the first stop/item in view: after the redraw it sits at the same spot on screen.
function renderLoad() {
  const y = window.scrollY, before = lastScreenKey;
  let anchor = null;
  for (const n of document.querySelectorAll('[data-key]')) {
    const r = n.getBoundingClientRect();
    if (r.bottom > 40) { anchor = { key: n.dataset.key, top: r.top }; break; }
  }
  drawLoad();
  const key = S.session ? JSON.stringify(S.screen || 'route') : null;
  lastScreenKey = key;
  if (key && key === before) {
    window.scrollTo(0, y);
    const n = anchor && [...document.querySelectorAll('[data-key]')].find(x => x.dataset.key === anchor.key);
    if (n) window.scrollBy(0, n.getBoundingClientRect().top - anchor.top);
  }
  syncHistory();
}

// The phone's Back button: a checklist / abort / QR screen has its own history entry, so Back
// returns to the route instead of leaving the app.
let histPushed = false;
function syncHistory() {
  if (S.session && S.screen && !histPushed) { history.pushState({ lm: 1 }, ''); histPushed = true; }
  else if (!(S.session && S.screen) && histPushed) { histPushed = false; history.back(); }
}
window.addEventListener('popstate', () => {
  if (!histPushed) return;
  histPushed = false;
  if (S.session && S.screen) { S.screen = null; S.form.editing = null; S.form.edit = null; S.form.refuseAll = null; renderLoad(); }
});
function drawLoad() {
  const d = view();
  if (!d) { renderScan(); return; }
  const loadWide = S.screen && ['abortload', 'qr'].includes(S.screen.kind);
  if (S.screen && S.screen.kind === 'qr' && !d.load.claim_code) S.screen = null;      // an older copy of the load: wait for the refresh
  const stop = S.screen && !loadWide ? d.stops.find(s => s.id === S.screen.stop) : null;
  if (S.screen && !loadWide && !stop) S.screen = null;
  if (S.screen && S.screen.kind === 'check' && stop && stop.status !== 'arrived') S.screen = null;   // finished, or moved on
  if (S.screen && S.screen.kind === 'abort' && stop && DONE.includes(stop.status)) S.screen = null;
  if (S.screen && S.screen.kind === 'abortload' && ['completed', 'closed'].includes(d.load.status)) S.screen = null;
  if (S.screen && S.screen.kind === 'check') return renderChecklist(d, stop);
  if (S.screen && S.screen.kind === 'abort') return renderAbort(d, stop);
  if (S.screen && S.screen.kind === 'abortload') return renderAbortLoad(d);
  if (S.screen && S.screen.kind === 'qr') return renderQr(d);
  renderRoute(d);
}

// What is still on the truck for the warehouse: items not delivered, per stop. Worked out
// on the phone, so it is right even with no signal.
function handBackList(stops) {
  const out = [];
  for (const s of stops) {
    if (!['partial', 'failed'].includes(s.status)) continue;
    const lines = (s.lines || []).map(l => ({ l, qty: Number(l.expected) - Number(l.delivered || 0) })).filter(x => x.qty > 0);
    if (lines.length) out.push({ stop: s, lines });
  }
  return out;
}
function handBackCard(stops) {
  const list = handBackList(stops);
  if (!list.length) return '';
  const total = list.reduce((n, x) => n + x.lines.length, 0);
  return `<h2>Hand back at the warehouse</h2>
    <div class="card handback">
      <p class="muted" style="margin-bottom:8px">${plural(total, 'item')} from ${plural(list.length, 'stop')} are still on your truck. Give them to the warehouse when you get back.</p>
      ${list.map(({ stop, lines }) => `<div class="hb"><div class="who">${esc(stop.customer_name || stop.customer_id)}</div>
        ${lines.map(({ l, qty }) => `<div class="hbl"><span>${esc(l.description || l.inventory_id)}</span><b>${num(qty)}${l.uom ? ' ' + esc(l.uom) : ''}</b>
          <small>${esc(reasonLabel(l.reason || stop.fail_reason))}</small></div>`).join('')}</div>`).join('')}
    </div>`;
}

function statusBanners() {
  const notice = S.notice; S.notice = null;
  const photos = S.waiting.size;
  return `${banner(notice)}
    ${S.offline ? '<div class="banner warn"><b>No signal.</b> Your taps are saved on this phone and will be sent when you have signal.</div>' : ''}
    ${S.queue.length ? `<div class="banner info"><span class="spin"></span><b>${plural(S.queue.length, 'action')} waiting to send.</b></div>` : ''}
    ${photos ? `<div class="banner info"><span class="spin"></span><b>${plural(photos, 'photo')} waiting to upload.</b> Keep this app installed; they send when you have signal.</div>` : ''}
    ${S.gpsDenied ? '<div class="banner warn"><b>Location is off.</b> Your deliveries are still saved, but without a location. Turn location on for this app in your phone settings.</div>' : ''}`;
}

// --- The load's QR, for security when the truck comes back ------------
// The same code as on the load sheet. It lives in the phone's copy of the load, so it shows
// with no signal.
function qrSvg(text) {
  const qr = qrcode(0, 'M');
  qr.addData(text);
  qr.make();
  const n = qr.getModuleCount(), cell = 4, size = n * cell;
  let rects = '';
  for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (qr.isDark(r, c)) rects += `<rect x="${c * cell}" y="${r * cell}" width="${cell}" height="${cell}"/>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-8 -8 ${size + 16} ${size + 16}" shape-rendering="crispEdges" role="img" aria-label="Load QR code"><rect x="-8" y="-8" width="${size + 16}" height="${size + 16}" fill="#fff"/><g fill="#000">${rects}</g></svg>`;
}
const prettyCode = c => String(c || '').slice(0, 4) + '-' + String(c || '').slice(4);
function renderQr(d) {
  const l = d.load;
  const link = new URL('./?c=' + l.claim_code, location.href).href;
  show(`
    <button class="btn link back" data-act="backroute">‹ Back to the route</button>
    <h1>Show this to security</h1>
    <p class="lead">When you are back at the warehouse, security scans this code to check your truck. It is the same code you scanned to collect the load.</p>
    <div class="card qrcard">
      <div class="qrbox">${qrSvg(link)}</div>
      <div class="loadnbr" style="text-align:center;margin-top:10px">${esc(l.load_nbr)}</div>
      <div class="qrcode">${esc(prettyCode(l.claim_code))}</div>
      <div class="muted" style="text-align:center">${esc(l.trucker)}</div>
    </div>
    <div class="btns"><button class="btn" data-act="backroute">Back to the route</button></div>`);
}

// --- Route ---------------------------------------------------------
function renderRoute(d) {
  const l = d.load, stops = d.stops || [];
  const invoices = stops.reduce((n, s) => n + (s.invoices || []).length, 0);
  const done = stops.filter(s => DONE.includes(s.status)).length;
  const active = stops.find(s => s.status === 'on_the_way' || s.status === 'arrived');
  const pending = stops.filter(s => s.status === 'pending');
  const firstPending = pending[0];
  const finished = l.status === 'completed' || l.status === 'closed';

  if (!S.warmed) { S.warmed = true; getPosition().then(() => { if (S.gpsDenied && S.session) rerender(); }); }

  show(`
    <h1>Your load</h1>
    ${statusBanners()}
    <div class="card">
      <div class="muted">Load number</div>
      <div class="loadnbr">${esc(l.load_nbr)}</div>
      <div class="forwho">${esc(l.trucker)}<small>${esc(l.ship_via || '')}${l.truck_type ? ' · ' + esc(l.truck_type) : ''}</small></div>
      <div class="muted" style="margin-top:8px">${plural(stops.length, 'stop')} · ${plural(invoices, 'invoice')}</div>
      <div class="prog"><i style="width:${stops.length ? Math.round(100 * done / stops.length) : 0}%"></i></div>
      <div class="kv" style="border:0;padding-top:4px"><span>Done</span><b>${done} of ${stops.length}</b></div>
    </div>
    ${l.aborted_at ? `<div class="banner bad"><b>You stopped this load</b> (${esc(reasonLabel(l.abort_reason))}${l.abort_note ? ': ' + esc(l.abort_note) : ''}). Take everything still on the truck back to the warehouse.</div>`
      : finished ? '<div class="banner ok"><b>All stops are done.</b> Wait for the office to close your load.</div>' : ''}
    ${active ? `<div class="banner info">You are ${active.status === 'arrived' ? 'at' : 'on the way to'} <b>${esc(active.customer_name || active.customer_id)}</b>. Finish this stop before starting the next.</div>` : ''}
    <div class="rowhead"><h2>Stops in order</h2>
      ${!S.editing && pending.length > 1 && !finished ? '<button class="btn small" data-act="editorder">Change order</button>' : ''}</div>
    ${S.editing ? editList(stops) : stops.map((s, i) => stopCard(s, i, { active, firstPending })).join('') || '<div class="card muted">No stops on this load.</div>'}
    ${S.editing ? '' : handBackCard(stops)}
    ${S.editing ? `<div class="btns"><button class="btn primary" data-act="saveorder">Save this order</button><button class="btn link" data-act="cancelorder">Cancel</button></div>`
      : `<div class="btns">${l.claim_code ? `<button class="btn ${finished ? 'primary' : ''}" data-act="qr">Show my load QR (for security)</button>` : ''}
          <button class="btn" data-act="refresh">Refresh</button>
          ${finished ? '' : '<button class="btn link" data-act="abortloadscreen">I can\'t finish this load</button>'}</div>`}`);
}

// Call / WhatsApp for the sales rep and sales support behind this customer (set up on the
// office's Contacts page). A contact with no number yet is listed by name only.
function contactRow(s) {
  const list = s.contacts || [];
  if (!list.length) return '';
  return `<div class="contacts">${list.map(c => c.phone
    ? `<div class="crow"><span class="cwho"><small>${esc(c.label)}</small>${esc(c.name || '')}</span>
        <a class="btn small" href="${esc(telHref(c.phone))}">📞 Call</a>
        <a class="btn small wa" href="https://wa.me/${esc(waNumber(c.phone))}" target="_blank" rel="noopener">WhatsApp</a></div>`
    : `<div class="crow"><span class="cwho"><small>${esc(c.label)}</small>${esc(c.name || '')} <span class="muted">(no number yet)</span></span></div>`).join('')}</div>`;
}

function stopCard(s, i, ctx) {
  const items = (s.lines || []).reduce((n, x) => n + Number(x.expected || 0), 0);
  const addr = tidyAddress(s.customer_name, s.address, s.city);
  const exceptions = (s.lines || []).filter(x => x.result && x.result !== 'delivered').length;
  let state = '', acts = '';
  if (s.status === 'pending') {
    if (!ctx.active) {
      const first = ctx.firstPending && ctx.firstPending.id === s.id;
      acts = `<button class="btn ${first ? 'primary' : ''}" data-act="otw" data-stop="${s.id}">On the way</button>`;
    }
    acts += `<button class="btn link" data-act="abortstop" data-stop="${s.id}">Can't deliver this stop</button>`;
  } else if (s.status === 'on_the_way') {
    state = `<span class="pill info">On the way since ${esc(timeOf(s.on_the_way_at))}</span>`;
    acts = `<button class="btn primary" data-act="arr" data-stop="${s.id}">Arrived</button>
            <button class="btn link" data-act="cancelotw" data-stop="${s.id}">I tapped On the way by mistake</button>
            <button class="btn link" data-act="abortstop" data-stop="${s.id}">Can't deliver this stop</button>`;
  } else if (s.status === 'arrived') {
    state = `<span class="pill warn">Arrived ${esc(timeOf(s.arrived_at))}</span>`;
    acts = `<button class="btn primary" data-act="openchecklist" data-stop="${s.id}">Check the delivery</button>
            <button class="btn link" data-act="abortstop" data-stop="${s.id}">Can't deliver this stop</button>`;
  } else if (s.status === 'delivered') {
    state = `<span class="pill ok">Delivered ${esc(timeOf(s.completed_at))}${s.receiver_name ? ' · ' + esc(s.receiver_name) : ''}</span>`;
  } else if (s.status === 'partial') {
    state = `<span class="pill warn">Partly delivered ${esc(timeOf(s.completed_at))}${s.receiver_name ? ' · ' + esc(s.receiver_name) : ''}</span>
             <div class="muted" style="margin-top:4px">${plural(exceptions, 'item')} not delivered</div>`;
  } else {
    state = `<span class="pill bad">Not delivered${s.fail_reason ? ' · ' + esc(reasonLabel(s.fail_reason)) : ''}</span>`;
  }
  const mapHref = addr ? 'https://www.google.com/maps/search/?api=1&query=' + encodeURIComponent((s.customer_name ? s.customer_name + ', ' : '') + addr + ', Jamaica') : '';
  return `<div class="card stopcard ${DONE.includes(s.status) ? 'done' : ctx.active && ctx.active.id === s.id ? 'active' : ''}" data-key="s${s.id}">
    <div class="stop"><div class="n">${i + 1}</div>
      <div>
        <div class="who">${esc(s.customer_name || s.customer_id)}</div>
        ${addr ? `<div class="addr">${esc(addr)} ${DONE.includes(s.status) ? '' : `<a class="tel" href="${esc(mapHref)}" target="_blank" rel="noopener">🗺 Directions</a>`}</div>` : ''}
        <div class="meta">${plural((s.invoices || []).length, 'invoice')} · ${fmt(items)} items${s.phone ? ` · <a class="tel" href="tel:${esc(String(s.phone).replace(/[^0-9+]/g, ''))}">${esc(s.phone)}</a>` : ''}</div>
        ${state ? `<div style="margin-top:8px">${state}</div>` : ''}
        ${s.status === 'delivered' ? '' : contactRow(s)}
      </div></div>
    ${acts ? `<div class="acts">${acts}</div>` : ''}
  </div>`;
}

// Customer addresses in Acumatica often start with the customer's own name and can have
// empty parts or repeat the town; show only the useful parts.
function tidyAddress(name, address, city) {
  const parts = String(address || '').split(',').map(x => x.trim()).filter(Boolean);
  if (parts.length && name && parts[0].toLowerCase() === String(name).trim().toLowerCase()) parts.shift();
  if (city && !parts.some(x => x.toLowerCase() === String(city).trim().toLowerCase())) parts.push(String(city).trim());
  return parts.join(', ');
}

// Edit order: only stops still waiting can move; the rest stay where they are.
function editList(stops) {
  const byId = new Map(stops.map(s => [s.id, s]));
  return `<p class="muted" style="margin:0 2px 10px">Hold the ☰ handle and drag a stop to where you will deliver it. Stops already visited stay where they are.</p>` +
    S.draft.map((id, i) => {
      const s = byId.get(id);
      const canMove = s.status === 'pending';
      return `<div class="card stopcard ${canMove ? 'movable' : 'done'}" data-id="${id}"><div class="stop"><div class="n">${i + 1}</div>
        <div style="flex:1"><div class="who">${esc(s.customer_name || s.customer_id)}</div>
          <div class="addr">${esc(tidyAddress(s.customer_name, s.address, s.city))}</div></div>
        ${canMove ? `<div class="grip" data-grip aria-label="Drag to move">☰</div>` : ''}
      </div></div>`;
    }).join('');
}

// Drag a stop by its handle. The cards move on screen as you drag; on release the new
// order goes into S.draft. Stops already visited keep their places.
let drag = null;
document.addEventListener('pointerdown', e => {
  const g = e.target.closest('[data-grip]');
  if (!g || !S.editing) return;
  e.preventDefault();
  g.setPointerCapture(e.pointerId);
  const card = g.closest('.stopcard');
  card.classList.add('dragging');
  drag = { card, id: e.pointerId };
});
document.addEventListener('pointermove', e => {
  if (!drag || e.pointerId !== drag.id) return;
  for (const c of document.querySelectorAll('.stopcard.movable')) {
    if (c === drag.card) continue;
    const r = c.getBoundingClientRect();
    if (e.clientY >= r.top && e.clientY <= r.bottom) {
      const after = !!(drag.card.compareDocumentPosition(c) & Node.DOCUMENT_POSITION_FOLLOWING);
      c.parentNode.insertBefore(drag.card, after ? c.nextSibling : c);
      break;
    }
  }
  if (e.clientY < 80) window.scrollBy(0, -12); else if (e.clientY > window.innerHeight - 80) window.scrollBy(0, 12);
});
function endDrag(e) {
  if (!drag || e.pointerId !== drag.id) return;
  const order = [...document.querySelectorAll('.stopcard.movable')].map(c => Number(c.dataset.id));
  const status = new Map(view().stops.map(s => [s.id, s.status]));
  let k = 0;
  S.draft = S.draft.map(id => status.get(id) === 'pending' ? order[k++] : id);
  drag = null;
  renderLoad();
}
document.addEventListener('pointerup', endDrag);
document.addEventListener('pointercancel', endDrag);

// --- Checklist ------------------------------------------------------
const RESULT_WORD = { short: 'Short', refused: 'Refused', damaged: 'Damaged' };
const lineReasons = (res, reasons) => (reasons || []).filter(r => ['line', 'both'].includes(r.applies_to));
const stopReasons = reasons => (reasons || []).filter(r => ['stop', 'both'].includes(r.applies_to));
const options = (list, cur) => `<option value="">Choose a reason…</option>` + list.map(r => `<option value="${esc(r.code)}" ${r.code === cur ? 'selected' : ''}>${esc(r.label)}</option>`).join('');

function photoList(stop, kind, lineId) {
  const files = (stop.files || []).filter(f => f.kind === kind && (lineId ? f.line_id === lineId : !f.line_id));
  if (!files.length) return '';
  return `<div class="photos">${files.map(f => {
    const wait = S.waiting.has(f.id);          // still on this phone; once the upload succeeds it is gone from here
    return `<span class="photo ${wait ? 'wait' : 'ok'}">📷 ${wait ? 'waiting to upload' : 'uploaded'}</span>`;
  }).join('')}</div>`;
}

function lineRow(stop, l, reasons) {
  const editing = S.form.editing === l.id;
  const unit = l.uom ? ' ' + esc(l.uom) : '';
  let state;
  if (!l.result) {
    state = `<div class="lbtns"><button class="btn ok" data-act="lfull" data-line="${l.id}">✓ In full</button>
             <button class="btn" data-act="lnot" data-line="${l.id}">Not all</button></div>`;
  } else if (l.result === 'delivered') {
    state = `<div class="lstate ok">✓ Delivered in full <button class="btn link" data-act="lnot" data-line="${l.id}">Change</button></div>`;
  } else {
    state = `<div class="lstate bad"><b>${RESULT_WORD[l.result]}:</b> ${num(l.delivered)} of ${num(l.expected)}${unit} delivered · ${esc(reasonLabel(l.reason))}${l.note ? ' · ' + esc(l.note) : ''}
             <button class="btn link" data-act="lnot" data-line="${l.id}">Change</button></div>${photoList(stop, 'damage', l.id)}`;
  }
  let editor = '';
  if (editing) {
    const e = S.form.edit;
    const list = lineReasons(null, reasons);
    const max = Math.max(0, Number(l.expected) - 1);
    const dmg = (list.find(r => r.code === e.reason) || {}).cause === 'damaged';
    editor = `<div class="editor">
      <label class="fld">Why?<select class="txt" id="e_reason">${options(list, e.reason)}</select></label>
      <label class="fld">How many did the customer get? (of ${num(l.expected)}${unit})<input class="txt" id="e_qty" type="number" inputmode="decimal" min="0" max="${max}" step="any" value="${esc(e.qty)}"></label>
      <button class="btn small" data-act="lzero" style="margin-top:8px">None of this was delivered</button>
      <label class="fld">Note (optional)<input class="txt" id="e_note" maxlength="200" value="${esc(e.note)}" autocomplete="off"></label>
      ${dmg ? `<button class="btn small" data-act="photo" data-kind="damage" data-line="${l.id}">📷 Photo of the damage</button>${photoList(stop, 'damage', l.id)}` : ''}
      <div class="btns" style="margin-top:10px"><button class="btn primary" data-act="lsave" data-line="${l.id}">Save</button>
        <button class="btn link" data-act="lcancel">Cancel</button></div>
    </div>`;
  }
  return `<div class="line ${l.result ? (l.result === 'delivered' ? 'm-ok' : 'm-bad') : ''}" data-key="l${l.id}">
    <div class="ld"><b>${esc(l.description || l.inventory_id)}</b><span>${num(l.expected)}${unit}</span></div>
    ${editing ? '' : state}${editor}</div>`;
}

function renderChecklist(d, stop) {
  const lines = stop.lines || [];
  const marked = lines.filter(l => l.result).length;
  const all = marked === lines.length;
  const outcome = all ? outcomeOf(stop) : null;
  const byInv = new Map();
  lines.forEach(l => { if (!byInv.has(l.shipment_nbr)) byInv.set(l.shipment_nbr, []); byInv.get(l.shipment_nbr).push(l); });
  const reasons = d.reasons;
  const rcv = S.form.receiver[stop.id] || '';
  const hasPod = (stop.files || []).some(f => f.kind === 'pod');
  const refuse = S.form.refuseAll;

  show(`
    <button class="btn link back" data-act="backroute">‹ Back to the route</button>
    <h1>${esc(stop.customer_name || stop.customer_id)}</h1>
    <p class="lead">Check what you handed over. Tap <b>In full</b> for each item, or <b>Not all</b> if something wasn't delivered.</p>
    ${statusBanners()}
    <div class="stickyprog">
      <div class="kv" style="border:0;padding:0 0 4px"><span>Items checked</span><b>${marked} of ${lines.length}</b></div>
      <div class="prog" style="margin-top:0"><i style="width:${lines.length ? Math.round(100 * marked / lines.length) : 0}%"></i></div>
    </div>
    <div class="card">
      <div class="btns" style="margin-top:0">
        <button class="btn" data-act="allfull" ${marked === lines.length ? 'disabled' : ''}>Everything delivered in full</button>
        <button class="btn warn" data-act="refuseall">Customer refused everything</button>
      </div>
      ${refuse ? `<div class="editor"><label class="fld">Why did the customer refuse?<select class="txt" id="r_reason">${options(lineReasons('refused', reasons), refuse.reason)}</select></label>
        <div class="btns" style="margin-top:10px"><button class="btn danger" data-act="refuseok" ${refuse.reason ? '' : 'disabled'}>Mark every item refused</button><button class="btn link" data-act="refusecancel">Cancel</button></div></div>` : ''}
    </div>
    ${[...byInv.entries()].map(([nbr, ls]) => `<h2>Invoice ${esc(nbr)}</h2><div class="card lines">${ls.map(l => lineRow(stop, l, reasons)).join('')}</div>`).join('')}
    <h2>Proof of delivery</h2>
    <div class="card">
      <label class="fld">Name of the person who received it<input class="txt" id="rcv" autocomplete="off" placeholder="For example: Ms Brown" value="${esc(rcv)}"></label>
      <div style="margin-top:12px"><button class="btn" data-act="photo" data-kind="pod">📷 ${hasPod ? 'Add another photo' : 'Photo of the signed invoice'}</button></div>
      ${photoList(stop, 'pod', null)}
      <p class="muted" style="margin-top:8px">One photo covers all ${plural((stop.invoices || []).length, 'invoice')} at this stop.</p>
    </div>
    ${all ? `<div class="banner ${outcome === 'delivered' ? 'ok' : outcome === 'partial' ? 'warn' : 'bad'}"><b>This will be recorded as: ${outcome === 'delivered' ? 'Delivered in full' : outcome === 'partial' ? 'Partly delivered' : 'Nothing delivered'}.</b></div>` : ''}
    <div class="btns">
      <button class="btn primary" data-act="finish" ${all ? '' : 'disabled'}>${all ? 'Finish this delivery' : `Check ${lines.length - marked} more ${lines.length - marked === 1 ? 'item' : 'items'}`}</button>
      <button class="btn link" data-act="abortstop" data-stop="${stop.id}">Can't deliver this stop</button>
    </div>`);
}

function startEdit(lineId) {
  const d = view();
  const stop = d.stops.find(s => s.id === S.screen.stop);
  const l = (stop.lines || []).find(x => x.id === lineId);
  const prev = l.result && l.result !== 'delivered';
  S.form.editing = lineId;
  S.form.edit = { qty: prev ? num(l.delivered) : '', reason: prev ? l.reason || '' : '', note: prev ? l.note || '' : '' };
  renderLoad();
  const q = el('e_qty');                       // ready to type: any old number is selected so typing replaces it
  if (q) { q.focus(); q.select(); }
}

function saveLine(lineId) {
  const e = S.form.edit;
  const d = view();
  const stop = d.stops.find(s => s.id === S.screen.stop);
  const l = (stop.lines || []).find(x => x.id === lineId);
  const expected = Number(l.expected);
  const qty = Number(e.qty);
  if (e.qty === '' || !isFinite(qty) || qty < 0 || qty >= expected) { toast(`How many did the customer get? It must be less than ${num(expected)}.`); return; }
  if (!e.reason) { toast('Choose a reason.'); return; }
  // The office still files each line as refused / damaged / short: worked out from the quantity and the reason.
  const cause = ((d.reasons || []).find(r => r.code === e.reason) || {}).cause;
  const result = qty === 0 ? 'refused' : cause === 'damaged' ? 'damaged' : 'short';
  S.form.editing = null; S.form.edit = null;
  enqueue([makeEvent('line_set', stop.id, { line_id: lineId, result, qty, reason_code: e.reason, note: (e.note || '').trim() || undefined })]);
}

function toast(msg) {
  const t = document.createElement('div');
  t.className = 'toast'; t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 3500);
}

function finishStop() {
  const d = view();
  const stop = d.stops.find(s => s.id === S.screen.stop);
  if ((stop.lines || []).some(l => !l.result)) return;
  const rcv = (S.form.receiver[stop.id] || '').trim();
  const hasPod = (stop.files || []).some(f => f.kind === 'pod');
  const out = outcomeOf(stop);
  const missing = [];
  if (out !== 'failed') { if (!hasPod) missing.push('a photo of the signed invoice'); if (!rcv) missing.push("the receiver's name"); }
  if (missing.length && !confirm(`You have not added ${missing.join(' or ')}.\n\nFinish anyway? The office will see that it is missing.`)) return;
  S.screen = null;
  press('complete', stop.id, rcv ? { receiver_name: rcv } : {}, true);
}

// --- Can't deliver this stop ---------------------------------------
function renderAbort(d, stop) {
  const list = stopReasons(d.reasons);
  show(`
    <button class="btn link back" data-act="backroute">‹ Back to the route</button>
    <h1>Can't deliver</h1>
    <p class="lead">${esc(stop.customer_name || stop.customer_id)}. The goods stay on your truck. The office will see why.</p>
    ${statusBanners()}
    <div class="card">
      <label class="fld">Why couldn't you deliver?<select class="txt" id="a_reason">${options(list, S.form.abortReason)}</select></label>
      <label class="fld" style="margin-top:12px">Note (optional)<input class="txt" id="a_note" maxlength="200" value="${esc(S.form.abortNote)}" autocomplete="off"></label>
      <div style="margin-top:12px"><button class="btn" data-act="photo" data-kind="abort" data-stop="${stop.id}">📷 Take a photo (optional)</button></div>
      ${photoList(stop, 'abort', null)}
    </div>
    <div class="btns">
      <button class="btn danger" data-act="abortok" data-stop="${stop.id}" ${S.form.abortReason ? '' : 'disabled'}>Can't deliver this stop</button>
      <button class="btn link" data-act="backroute">Cancel</button>
    </div>`);
}

// --- I can't finish this load --------------------------------------
const loadReasons = reasons => (reasons || []).filter(r => r.applies_to === 'load' || r.code === 'other');
function renderAbortLoad(d) {
  const open = d.stops.filter(s => ['pending', 'on_the_way', 'arrived'].includes(s.status)).length;
  show(`
    <button class="btn link back" data-act="backroute">‹ Back to the route</button>
    <h1>I can't finish this load</h1>
    <p class="lead">${plural(open, 'stop')} not yet delivered will be marked as not delivered, and the items on your truck go back to the warehouse. The office is told at once.</p>
    ${statusBanners()}
    <div class="card">
      <label class="fld">What happened?<select class="txt" id="l_reason">${options(loadReasons(d.reasons), S.form.loadReason)}</select></label>
      <label class="fld" style="margin-top:12px">Tell the office more (optional)<input class="txt" id="l_note" maxlength="200" value="${esc(S.form.loadNote)}" autocomplete="off"></label>
    </div>
    <div class="btns">
      <button class="btn danger" data-act="abortloadok" ${S.form.loadReason ? '' : 'disabled'}>Stop this load</button>
      <button class="btn link" data-act="backroute">Cancel</button>
    </div>`);
}

// ------------------------------------------------------------------
// Events and start-up
// ------------------------------------------------------------------
document.addEventListener('click', e => {
  const b = e.target.closest('[data-act]');
  if (!b) return;
  const stop = b.dataset.stop ? Number(b.dataset.stop) : null;
  const line = b.dataset.line ? Number(b.dataset.line) : null;
  const cur = () => S.screen && S.screen.stop;
  switch (b.dataset.act) {
    case 'scan': renderScan(); break;
    case 'typecode': renderTypeCode(); break;
    case 'codego': {
      const code = extractCode(el('codein').value);
      if (!code) { renderTypeCode({ kind: 'bad', html: 'A code has 8 letters and numbers. Check it and try again.' }); break; }
      doPeek(code); break;
    }
    case 'claim': doClaim(); break;
    case 'missing': { const m = el('missingbox'); m.hidden = !m.hidden; if (!m.hidden) el('missingnote').focus(); break; }
    case 'sendmissing': sendMissing(); break;
    case 'review': renderReview(); break;
    case 'refresh': refreshLoad().then(() => { if (!S.offline) toast('Up to date'); }); break;
    case 'qr': S.screen = { kind: 'qr' }; renderLoad(); break;
    case 'otw': press('on_the_way', stop, {}, true); break;
    case 'arr': press('arrived', stop, {}, true, { kind: 'check', stop }); break;
    case 'cancelotw': press('cancel_on_the_way', stop, {}, false); break;
    case 'editorder': S.editing = true; S.draft = view().stops.map(s => s.id); renderLoad(); break;
    case 'cancelorder': S.editing = false; renderLoad(); break;
    case 'saveorder': {
      const order = S.draft.slice();
      S.editing = false;
      press('seq_edit', null, { order }, false);
      break;
    }
    // checklist
    case 'openchecklist': S.screen = { kind: 'check', stop }; S.form.editing = null; S.form.edit = null; S.form.refuseAll = null; renderLoad(); break;
    case 'backroute': S.screen = null; S.form.editing = null; S.form.edit = null; S.form.refuseAll = null; renderLoad(); break;
    case 'lfull': enqueue([makeEvent('line_set', cur(), { line_id: line, result: 'delivered' })]); break;
    case 'lnot': startEdit(line); break;
    case 'lzero': S.form.edit.qty = '0'; renderLoad(); break;
    case 'lsave': saveLine(line); break;
    case 'lcancel': S.form.editing = null; S.form.edit = null; renderLoad(); break;
    case 'allfull': {
      const st = view().stops.find(s => s.id === cur());
      const evs = (st.lines || []).filter(l => l.result !== 'delivered').map(l => makeEvent('line_set', st.id, { line_id: l.id, result: 'delivered' }));
      if (evs.length) enqueue(evs);
      break;
    }
    case 'refuseall': S.form.refuseAll = { reason: '' }; renderLoad(); break;
    case 'refusecancel': S.form.refuseAll = null; renderLoad(); break;
    case 'refuseok': {
      const st = view().stops.find(s => s.id === cur());
      const reason = S.form.refuseAll.reason;
      S.form.refuseAll = null;
      enqueue((st.lines || []).map(l => makeEvent('line_set', st.id, { line_id: l.id, result: 'refused', reason_code: reason })));
      break;
    }
    case 'photo': takePhoto(b.dataset.kind, stop || cur(), line); break;
    case 'finish': finishStop(); break;
    // can't finish the load
    case 'abortloadscreen': S.screen = { kind: 'abortload' }; S.form.loadReason = ''; S.form.loadNote = ''; renderLoad(); break;
    case 'abortloadok': {
      if (!S.form.loadReason) break;
      if (!confirm("Stop this load?\n\nEvery stop you haven't delivered will be marked as not delivered.")) break;
      const payload = { reason_code: S.form.loadReason, note: (S.form.loadNote || '').trim() || undefined };
      S.screen = null;
      press('abort_load', null, payload, true);
      break;
    }
    // can't deliver
    case 'abortstop': S.screen = { kind: 'abort', stop }; S.form.abortReason = ''; S.form.abortNote = ''; renderLoad(); break;
    case 'abortok': {
      const st = view().stops.find(s => s.id === stop);
      if (!S.form.abortReason) break;
      if (!confirm(`Can't deliver to ${st.customer_name || st.customer_id}?\n\nThe goods stay on your truck.`)) break;
      const payload = { reason_code: S.form.abortReason, note: (S.form.abortNote || '').trim() || undefined };
      S.screen = null;
      press('abort_stop', stop, payload, true);
      break;
    }
  }
});

// What the driver types is kept in S.form so a refresh doesn't lose it.
document.addEventListener('input', e => {
  const t = e.target;
  if (t.id === 'rcv' && S.screen) S.form.receiver[S.screen.stop] = t.value;
  else if (t.id === 'e_qty' && S.form.edit) S.form.edit.qty = t.value;
  else if (t.id === 'e_note' && S.form.edit) S.form.edit.note = t.value;
  else if (t.id === 'a_note') S.form.abortNote = t.value;
  else if (t.id === 'l_note') S.form.loadNote = t.value;
});
document.addEventListener('change', e => {
  const t = e.target;
  if (t.id === 'e_reason' && S.form.edit) { S.form.edit.reason = t.value; renderLoad(); }
  else if (t.id === 'r_reason' && S.form.refuseAll) { S.form.refuseAll.reason = t.value; renderLoad(); }
  else if (t.id === 'a_reason') { S.form.abortReason = t.value; renderLoad(); }
  else if (t.id === 'l_reason') { S.form.loadReason = t.value; renderLoad(); }
});
document.addEventListener('keydown', e => {
  if (e.key === 'Enter' && e.target && e.target.id === 'codein') { e.preventDefault(); document.querySelector('[data-act=codego]').click(); }
});
document.addEventListener('visibilitychange', () => {
  if (document.hidden) stopScan();
  else if (S.session) { refreshLoad(); uploadPhotos(); }
});

async function boot() {
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
  setOffline(!navigator.onLine);
  // A link from the phone's own camera app carries the code: driver/?c=ABCD1234
  const q = new URLSearchParams(location.search).get('c');
  const fromLink = q ? extractCode(q) : null;
  if (q) history.replaceState(null, '', location.pathname);

  S.session = LS.get('lm.session');
  S.data = LS.get('lm.data');
  S.queue = LS.get('lm.queue') || [];
  setInterval(() => { if (S.session) { if (S.queue.length) flush(); else uploadPhotos(); } }, SYNC_EVERY_MS);
  setInterval(() => { if (S.session && !S.queue.length && !document.hidden) refreshLoad(); }, REFRESH_EVERY_MS);
  if (S.session && S.data) { await countPhotos(); renderLoad(); refreshLoad(); uploadPhotos(); return; }   // a driver with a load sees only that load
  LS.del('lm.session'); LS.del('lm.data'); LS.del('lm.queue');
  S.session = null; S.data = null; S.queue = [];
  if (fromLink) doPeek(fromLink); else renderScan();
}
boot();
