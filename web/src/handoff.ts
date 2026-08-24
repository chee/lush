const HANDOFF_CHANNEL = "@patchwork/handoff";
const CACHEABLE_STATUSES = [200, 203, 204];

type ResolveResult = {
  status: number;
  mimeType: string;
  base64: string;
  immutable: boolean;
};

declare global {
  interface Window {
    __patchworkResolve?: (raw: string) => Promise<ResolveResult>;
  }
}

async function handleRequest(
  channel: BroadcastChannel,
  data: Record<string, any>,
) {
  const id = typeof data.id === "string" ? data.id : undefined;
  if (!id) return;
  try {
    const { cachename, request } = data as {
      cachename: string;
      request: {
        url: string;
        handoffURL: string;
        headers: Record<string, string>;
        method: string;
        referrer: string;
      };
    };
    if (typeof cachename !== "string" || !request) {
      throw new Error("invalid handoff request");
    }

    const handoffURL = new URL(request.handoffURL);
    if (handoffURL.protocol !== "automerge:") {
      throw new Error("unsupported handoff url");
    }

    const resolve = window.__patchworkResolve;
    if (!resolve) throw new Error("resolver unavailable");

    const raw = new URL(request.url).pathname.slice(1);
    const result = await resolve(raw);
    const bytes = Uint8Array.from(atob(result.base64), (c) => c.charCodeAt(0));

    if (result.immutable && CACHEABLE_STATUSES.includes(result.status)) {
      try {
        const response = new Response(result.status === 204 ? null : bytes, {
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
          response,
        );
        channel.postMessage({ id, type: "cached" });
        return;
      } catch {}
    }

    channel.postMessage({
      id,
      type: "response",
      response: {
        status: result.status,
        body: bytes,
        headers: { "content-type": result.mimeType },
      },
    });
  } catch (error) {
    try {
      channel.postMessage({
        id,
        type: "response",
        response: {
          status: 500,
          body: new TextEncoder().encode(String(error)),
          headers: { "content-type": "text/plain" },
        },
      });
    } catch {}
  }
}

export function installHandoffListener() {
  const channel = new BroadcastChannel(HANDOFF_CHANNEL);

  channel.addEventListener("message", (event) => {
    const data = event.data;
    if (data?.type !== "request") return;
    void handleRequest(channel, data);
  });

  channel.postMessage({ type: "online" });
}
