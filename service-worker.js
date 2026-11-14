"use strict";

const CACHE = "snake-express-v2";
const ASSETS = ["./", "./index.html", "./style.css", "./game.js", "./manifest.webmanifest", "./icon-180.png", "./icon-192.png", "./icon-512.png"];

self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(ASSETS)));
});

self.addEventListener("activate", event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(
    keys.filter(key => key.startsWith("snake-express-") && key !== CACHE).map(key => caches.delete(key))
  )));
});

self.addEventListener("fetch", event => {
  if (event.request.method !== "GET" || new URL(event.request.url).origin !== self.location.origin) return;
  if (event.request.mode === "navigate") {
    event.respondWith(fetch(event.request).catch(() => caches.match("./index.html")));
  } else {
    event.respondWith(caches.match(event.request).then(response => response || fetch(event.request)));
  }
});
