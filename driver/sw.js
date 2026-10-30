// Service worker for the OMS driver app: keeps the app shell and the two pinned
// libraries available with no signal. Data calls (Supabase) always go to the network;
// the app keeps its own copy of the load in localStorage.
const CACHE = 'lm-driver-v7';
const SHELL = [
  './', 'index.html', 'driver.css', 'tokens.css', 'app.js', 'manifest.webmanifest', 'icon-192.png', 'icon-512.png',
  '../assets/dfl-logo-white.png',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.3',
  'https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js',
  'https://cdnjs.cloudflare.com/ajax/libs/qrcode-generator/1.4.4/qrcode.min.js',
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => Promise.all(SHELL.map(u =>
    c.add(new Request(u, { cache: 'reload' })).catch(() => {})))).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.hostname.endsWith('supabase.co')) return;            // data: never cached
  if (url.origin === self.location.origin) {
    // Our own files: network first so an update shows up, cache when offline.
    e.respondWith(fetch(req).then(res => {
      const copy = res.clone();
      caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
      return res;
    }).catch(() => caches.match(req, { ignoreSearch: true }).then(r => r || caches.match('index.html'))));
    return;
  }
  // Pinned CDN files and fonts: cache first.
  e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(res => {
    if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {}); }
    return res;
  })));
});
