// Service worker de Praxia.
//
// Solo cachea el armazón de la app: HTML, logo e íconos. Los datos NUNCA se
// guardan aquí. Es una app con expedientes clínicos: dejar respuestas de la
// base en el caché del navegador significaría que los datos de un paciente
// sobreviven al cierre de sesión y quedan legibles en el teléfono.
//
// Resultado: sin internet la app abre y explica que no hay conexión, en vez
// de mostrar el error del navegador. Pero no muestra datos viejos.

const VERSION = 'praxia-v1';

const ARMAZON = [
  './app.html',
  './assets/praxia-logo-completo.png',
  './assets/praxia-isotipo.png',
  './assets/icono-192.png',
  './assets/icono-512.png',
  './manifest.json',
];

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(VERSION)
      .then((c) => c.addAll(ARMAZON))
      .then(() => self.skipWaiting())
      .catch(() => self.skipWaiting()), // si un archivo falla, no bloquear la instalación
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((claves) => Promise.all(
        claves.filter((k) => k !== VERSION).map((k) => caches.delete(k)),
      ))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);

  // Todo lo que sea datos o sesión va directo a la red, sin pasar por caché.
  const esDatos = url.hostname.endsWith('supabase.co')
    || url.pathname.includes('/rest/')
    || url.pathname.includes('/auth/')
    || url.pathname.includes('/functions/');

  if (e.request.method !== 'GET' || esDatos) return;

  // El armazón se sirve de la red y se refresca en caché; si no hay red, del
  // caché. Así una versión nueva llega sola sin que nadie borre nada.
  e.respondWith(
    fetch(e.request)
      .then((r) => {
        const copia = r.clone();
        caches.open(VERSION).then((c) => c.put(e.request, copia)).catch(() => {});
        return r;
      })
      .catch(() => caches.match(e.request).then((r) => r || caches.match('./app.html'))),
  );
});

// ---------------------------------------------------------------------
// Avisos push
// ---------------------------------------------------------------------
// El push llega sin contenido cifrado, así que el texto vive aquí. Es a
// propósito: lo que se muestra aparece en la pantalla bloqueada del
// teléfono, donde no debe ir nada de un paciente. El detalle se ve al
// abrir la app, que es donde hay sesión iniciada.

self.addEventListener('push', (e) => {
  let datos = {};
  try { datos = e.data ? e.data.json() : {}; } catch (_) {}

  const titulo = datos.titulo || 'Tienes algo nuevo en Praxia';
  const cuerpo = datos.cuerpo || 'Abre la app para verlo.';

  e.waitUntil(
    self.registration.showNotification(titulo, {
      body: cuerpo,
      icon: './assets/icono-192.png',
      badge: './assets/icono-192.png',
      lang: 'es-MX',
      tag: 'praxia',           // los avisos se reemplazan, no se apilan
      renotify: true,
      data: { url: datos.url || './app.html' },
    }),
  );
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const destino = (e.notification.data && e.notification.data.url) || './app.html';

  // Si la app ya está abierta se enfoca esa ventana, en vez de abrir otra.
  e.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((ventanas) => {
      for (const v of ventanas) {
        if (v.url.includes('app.html') && 'focus' in v) return v.focus();
      }
      return self.clients.openWindow(destino);
    }),
  );
});
