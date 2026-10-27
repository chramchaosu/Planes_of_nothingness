"use strict";

/*
 * Service worker: lets the app open without internet once it has been loaded
 * from its web address (GitHub Pages).
 *
 * Strategy: "network first, with a time limit". When online, the newest
 * version is fetched and a copy is kept, so new episodes arrive on their own.
 * If the network is missing or slow, the kept copy is shown instead and the
 * download carries on in the background for next time.
 *
 * Change CACHE_NAME when the list of files below changes.
 */

const CACHE_NAME = "planes-of-nothingness-v1";
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

// Remove copies kept by older versions of this file.
self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((names) => Promise.all(names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET" || new URL(request.url).origin !== self.location.origin) return;

  const fromNetwork = fetch(request).then((response) => {
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
