// Vault Ledger — service worker
// แคชแค่ "เปลือกแอป" (index.html, manifest, ไอคอน) เพื่อให้เปิดเร็วขึ้น/เปิดได้แม้เน็ตช้า
// ไม่แคชและไม่แทรกแซง request ไปยัง Supabase (ข้อมูลจริงต้องออนไลน์เสมอ)
const CACHE_NAME = 'vault-ledger-shell-v1';
const SHELL_FILES = ['./', './index.html', './manifest.json', './icon-192.png', './icon-512.png'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_FILES)).catch(() => {})
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  // เฉพาะ request ที่มาจากโดเมนเดียวกัน (ตัวเว็บเอง) เท่านั้นที่เข้า cache-first
  // ปล่อย request ไปยัง Supabase หรือโดเมนอื่นให้วิ่งผ่าน network ตามปกติเสมอ
  if (url.origin !== self.location.origin) return;
  if (event.request.method !== 'GET') return;

  event.respondWith(
    caches.match(event.request).then((cached) => {
      const network = fetch(event.request)
        .then((res) => {
          if (res && res.ok) {
            const clone = res.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
          }
          return res;
        })
        .catch(() => cached);
      return cached || network;
    })
  );
});
