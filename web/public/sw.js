// v4: v3 can hold bytes a pinned folder resolved through a headless child,
// which were never immutable. There is no way to tell those entries apart.
const HANDOFF_CACHE = "patchwork-handoff-v4";
const EXTERNAL_CACHE = "patchwork-external-v1";
const ACTIVE_CACHES = new Set([HANDOFF_CACHE, EXTERNAL_CACHE]);
const CACHEABLE_STATUSES = [200, 203, 204];
const NULL_BODY_STATUSES = new Set([204, 205, 304]);
const EXTERNAL_CACHE_LIMIT = 128;
const HANDOFF_CHANNEL = "@patchwork/handoff";
const HANDOFF_TIMEOUT_MS = 35_000;

self.addEventListener("install", (event) => {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((key) => !ACTIVE_CACHES.has(key))
            .map((key) => caches.delete(key).catch(() => false))
        )
      )
      .catch(() => {})
      .then(() => self.clients.claim())
  );
});

const handoffChannel = new BroadcastChannel(HANDOFF_CHANNEL);
const pendingHandoffs = new Map();

handoffChannel.addEventListener("message", (event) => {
  const { data } = event;
  if (data?.type === "cached" || data?.type === "response") {
    pendingHandoffs.get(data.id)?.resolve(data);
    return;
  }
  if (data?.type === "online") {
    for (const { message } of pendingHandoffs.values()) {
      handoffChannel.postMessage(message);
    }
  }
});

/** Same-origin path that decodes to a URL with a different scheme, e.g. /automerge%3Aabc */
function specialURLFor(url) {
  if (
    url.hostname !== self.location.hostname ||
    url.port !== self.location.port ||
    url.protocol !== self.location.protocol
  )
    return undefined;
  try {
    return new URL(decodeURIComponent(url.pathname.slice(1)));
  } catch {
    return undefined;
  }
}

async function openCache(name) {
  try {
    return await caches.open(name);
  } catch {
    return undefined;
  }
}

async function cacheMatch(cache, request) {
  if (!cache) return undefined;
  try {
    return (await cache.match(request)) ?? (await cache.match(request.url));
  } catch {
    return undefined;
  }
}

async function serveHandoff(request, cache, handoffURL, cached) {
  if (cached) return cached;

  const id = crypto.randomUUID();
  let resolveReply;
  const promise = new Promise((resolve) => {
    resolveReply = resolve;
  });
  const message = {
    id,
    type: "request",
    cachename: HANDOFF_CACHE,
    request: {
      url: request.url,
      handoffURL: handoffURL.href,
      headers: Object.fromEntries(request.headers.entries()),
      method: request.method,
      destination: request.destination,
      referrer: request.referrer,
    },
  };

  pendingHandoffs.set(id, { message, resolve: resolveReply });
  const timer = setTimeout(() => {
    pendingHandoffs.delete(id);
    resolveReply(null);
  }, HANDOFF_TIMEOUT_MS);
  try {
    handoffChannel.postMessage(message);
  } catch {
    clearTimeout(timer);
    pendingHandoffs.delete(id);
    const response = await fetch(request).catch(() => undefined);
    return response ?? Response.error();
  }

  const reply = await promise;
  clearTimeout(timer);
  pendingHandoffs.delete(id);

  if (!reply) {
    // Timeout: fall back to the native scheme handler
    const response = await fetch(request).catch(() => undefined);
    return response ?? Response.error();
  }

  if (reply.type === "response") {
    try {
      if (!reply.response || typeof reply.response !== "object")
        throw new Error("invalid handoff response");
      const status = reply.response.status ?? 200;
      return new Response(
        NULL_BODY_STATUSES.has(status) ? null : (reply.response.body ?? null),
        {
          status,
          headers: reply.response.headers ?? {},
        }
      );
    } catch {
      const response = await fetch(request).catch(() => undefined);
      return response ?? Response.error();
    }
  }

  const storedCache = cache ?? (await openCache(HANDOFF_CACHE));
  return (await cacheMatch(storedCache, request)) ?? Response.error();
}

async function trimExternalCache(cache) {
  const keys = await cache.keys();
  const excess = keys.length - EXTERNAL_CACHE_LIMIT;
  if (excess <= 0) return;
  await Promise.all(
    keys.slice(0, excess).map((request) => cache.delete(request))
  );
}

async function serveExternal(request) {
  const cache = await openCache(EXTERNAL_CACHE);
  const cached = await cacheMatch(cache, request);
  try {
    const response = await fetch(request);
    if (cache && CACHEABLE_STATUSES.includes(response.status)) {
      try {
        await cache.put(request, response.clone());
        await trimExternalCache(cache);
      } catch {}
    }
    return response;
  } catch {
    // An opaque response hides the origin's status, so a cached error page is
    // indistinguishable from content — never serve one as the real thing.
    return cached && cached.status !== 0 ? cached : Response.error();
  }
}

self.addEventListener("fetch", (fetchEvent) => {
  const { request } = fetchEvent;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  const handoffURL = specialURLFor(url);
  const external =
    url.protocol === "https:" && url.origin !== self.location.origin;

  if (!handoffURL && !external) return;

  fetchEvent.respondWith(
    (async () => {
      if (handoffURL) {
        const cache = await openCache(HANDOFF_CACHE);
        const cached = await cacheMatch(cache, request);
        return serveHandoff(request, cache, handoffURL, cached);
      }
      return serveExternal(request);
    })()
  );
});
