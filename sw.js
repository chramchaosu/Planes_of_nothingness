"use strict";

/*
 * Service worker: lets the app open without internet once it has been loaded
 * from its web address (GitHub Pages).
 *
 * The app itself (index.html, icons, ...) is "network first, with a time limit":
 * when online, the newest version is fetched and a copy is kept, so new
 * episodes arrive on their own. If the network is missing or slow, the kept
 * copy is shown instead and the download carries on in the background.
 *
 * Comic pages (pages/..., pictures and short videos) are "saved copy first". Their file names contain
 * a fingerprint of their contents, so a name never points to a different
 * picture and a saved copy can't go out of date. The reader page fills this
 * cache with every page in the background, so the whole comic works offline.
 *
 * Change CACHE_NAME when the list of APP_FILES below changes.
 * PAGES_CACHE must match the name used in src/reader.html.
 */

const CACHE_NAME = "planes-of-nothingness-v3";
const PAGES_CACHE = "planes-of-nothingness-pages";
const APP_FILES = [
  "./",
  "./index.html",
  "./manifest.webmanifest",
  "./icon-180.png",
  "./icon-192.png",
  "./icon-512.png",
];
const NETWORK_TIMEOUT_MS = 4000;

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_FILES)));
  self.skipWaiting();
});

// Remove copies kept by older versions of this file (the saved pages stay).
self.addEventListener("activate", (event) => {
  const keep = new Set([CACHE_NAME, PAGES_CACHE]);
  event.waitUntil(
    caches.keys()
      .then((names) => Promise.all(names.filter((n) => !keep.has(n)).map((n) => caches.delete(n))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== self.location.origin) return;

  if (url.pathname.includes("/pages/")) {
    event.respondWith(savedCopyFirst(request));
    return;
  }

  // "no-cache": always ask the server whether there is something newer (cheap when nothing
  // changed), instead of reusing the browser's own copy for up to 10 minutes.
  const fromNetwork = fetch(request.url, { cache: "no-cache", credentials: "same-origin" }).then((response) => {
    if (response.ok) {
      const copy = response.clone();
      caches.open(CACHE_NAME).then((cache) => cache.put(request, copy));
    }
    return response;
  });
  // Keep the service worker alive until the download (and its saved copy) finishes.
  event.waitUntil(fromNetwork.catch(() => {}));

  event.respondWith(firstUsable(request, fromNetwork));
});

/** A comic page: the saved copy if there is one, otherwise download and save it. */
async function savedCopyFirst(request) {
  const cache = await caches.open(PAGES_CACHE);
  const cached = await cache.match(request);
  // Videos are read in pieces (a "Range" request), and Safari only plays one when it
  // gets exactly the piece it asked for.
  const range = request.headers.get("range");
  if (cached) return range ? piece(cached, range) : cached;
  // A piece can't be saved on its own; the reader saves the whole video in the background.
  if (range) return fetch(request);

  const response = await fetch(request);
  if (response.ok) await cache.put(request, response.clone());
  return response;
}

/** The part of a saved file named by a Range header such as "bytes=0-1" or "bytes=1000-". */
async function piece(response, range) {
  const body = await response.blob();
  const size = body.size;
  const match = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
  let start = NaN;
  let end = size - 1;
  if (match && match[1] !== "") {
    start = Number(match[1]);
    if (match[2] !== "") end = Math.min(Number(match[2]), size - 1);
  } else if (match && match[2] !== "") {
    start = Math.max(0, size - Number(match[2])); // "bytes=-500": the last 500 bytes
  }
  if (!(start <= end)) {
    return new Response(null, { status: 416, headers: { "Content-Range": `bytes */${size}` } });
  }
  return new Response(body.slice(start, end + 1), {
    status: 206,
    headers: {
      "Content-Type": response.headers.get("Content-Type") ?? "",
      "Content-Range": `bytes ${start}-${end}/${size}`,
      "Content-Length": String(end - start + 1),
      "Accept-Ranges": "bytes",
    },
  });
}

/** The network answer if it comes in time, otherwise the saved copy. */
async function firstUsable(request, fromNetwork) {
  const timedOut = new Promise((resolve) => setTimeout(resolve, NETWORK_TIMEOUT_MS, null));
  const quick = await Promise.race([fromNetwork.catch(() => null), timedOut]);
  if (quick) return quick;

  const cached = await caches.match(request, { ignoreSearch: true })
    ?? (request.mode === "navigate" ? await caches.match("./index.html") : undefined);
  if (cached) return cached;

  // Nothing saved yet (first visit on a slow connection): keep waiting for the network.
  return fromNetwork.catch(() => Response.error());
}
