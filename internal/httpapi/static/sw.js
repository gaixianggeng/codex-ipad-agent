const CACHE_NAME = "codex-ipad-agent-v11";
const APP_SHELL = [
  "/app.css?v=11",
  "/terminal-log.js?v=11",
  "/app.js?v=11",
  "/manifest.webmanifest",
  "/icons/icon.svg",
  "/vendor/xterm/xterm.css",
  "/vendor/xterm/xterm.js",
  "/vendor/addon-fit/addon-fit.js"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL)).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);

  // API 和 WebSocket 必须始终走网络，避免缓存 session 状态或 token 相关响应。
  if (url.pathname.startsWith("/api/")) {
    return;
  }

  if (event.request.method !== "GET") {
    return;
  }

  // HTML 入口必须优先走网络，否则 iPad PWA 很容易继续运行旧 app shell。
  if (event.request.mode === "navigate" || url.pathname === "/") {
    event.respondWith(
      fetch(event.request).catch(() =>
        caches
          .match(event.request)
          .then((cached) => cached || new Response("离线，无法加载 Codex 控制台", { status: 503, headers: { "Content-Type": "text/plain; charset=utf-8" } }))
      )
    );
    return;
  }

  event.respondWith(
    caches.match(event.request).then((cached) => {
      if (cached) return cached;
      return fetch(event.request).then((response) => {
        if (!response || response.status !== 200 || response.type !== "basic") {
          return response;
        }
        const copy = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
        return response;
      });
    })
  );
});
