const CACHE = "patchwork-v1";
const CACHEABLE_STATUSES = [0, 200, 203, 204];
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
        Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
      )
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

async function serveHandoff(fetchEvent, cache, handoffURL, cached) {
  if (cached) return cached;

  const id = crypto.randomUUID();
  const { promise, resolve } = Promise.withResolvers();
  const message = {
    id,
    type: "request",
    cachename: CACHE,
    request: {
      url: fetchEvent.request.url,
      handoffURL: handoffURL.href,
      headers: Object.fromEntries(fetchEvent.request.headers.entries()),
      method: fetchEvent.request.method,
      destination: fetchEvent.request.destination,
      referrer: fetchEvent.request.referrer,
    },
  };

  pendingHandoffs.set(id, { message, resolve });
  handoffChannel.postMessage(message);
  fetchEvent.waitUntil(promise.catch(() => {}));

  const timer = setTimeout(() => {
    pendingHandoffs.delete(id);
    resolve(null);
  }, HANDOFF_TIMEOUT_MS);

  const reply = await promise;
  clearTimeout(timer);
  pendingHandoffs.delete(id);

  if (!reply) {
    // Timeout: fall back to the native scheme handler
    const response = await fetch(fetchEvent.request).catch(() => undefined);
    if (response?.ok) cache.put(fetchEvent.request, response.clone());
    return response ?? Response.error();
  }

  if (reply.type === "response") {
    return new Response(reply.response.body ?? null, {
      status: reply.response.status ?? 200,
      headers: reply.response.headers ?? {},
    });
  }

  return (await cache.match(fetchEvent.request)) ?? Response.error();
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
    caches.open(CACHE).then(async (cache) => {
      const cached =
        (await cache.match(request)) ?? (await cache.match(request.url));

      if (handoffURL) {
        return serveHandoff(fetchEvent, cache, handoffURL, cached);
      }

      try {
        const response = await fetch(request);
        if (CACHEABLE_STATUSES.includes(response.status)) {
          cache.put(request, response.clone());
        }
        return response;
      } catch {
        return cached ?? Response.error();
      }
    })
  );
});
