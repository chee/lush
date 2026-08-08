const HANDOFF_CHANNEL = "@patchwork/handoff";
const CACHEABLE_STATUSES = [200, 203, 204];

type ResolveResult = { status: number; mimeType: string; base64: string };

declare global {
  interface Window {
    __patchworkResolve?: (raw: string) => Promise<ResolveResult>;
  }
}

export function installHandoffListener() {
  const channel = new BroadcastChannel(HANDOFF_CHANNEL);

  channel.addEventListener("message", async (event) => {
    const data = event.data;
    if (data?.type !== "request") return;

    const { id, cachename, request } = data as {
      id: string;
      cachename: string;
      request: {
        url: string;
        handoffURL: string;
        headers: Record<string, string>;
        method: string;
        referrer: string;
      };
    };

    let handoffURL: URL;
    try {
      handoffURL = new URL(request.handoffURL);
    } catch {
      return;
    }

    if (handoffURL.protocol !== "automerge:") return;

    const resolve = window.__patchworkResolve;
    if (!resolve) return;

    const raw = new URL(request.url).pathname.slice(1);
    const result = await resolve(raw);
    const bytes = Uint8Array.from(atob(result.base64), (c) => c.charCodeAt(0));

    if (CACHEABLE_STATUSES.includes(result.status)) {
      const response = new Response(bytes, {
        status: result.status,
        headers: { "content-type": result.mimeType },
      });
      const cache = await caches.open(cachename);
      await cache.put(
        new Request(request.url, {
          method: request.method,
          headers: request.headers,
          referrer: request.referrer,
        }),
        response
      );
      channel.postMessage({ id, type: "cached" });
    } else {
      channel.postMessage({
        id,
        type: "response",
        response: {
          status: result.status,
          body: new TextDecoder().decode(bytes),
          headers: { "content-type": result.mimeType },
        },
      });
    }
  });

  channel.postMessage({ type: "online" });
}
