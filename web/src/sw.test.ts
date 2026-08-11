import { readFileSync } from "node:fs";
import vm from "node:vm";
import { afterEach, describe, expect, test, vi } from "vitest";

class TestBroadcastChannel {
  readonly messages: unknown[] = [];
  listener?: (event: { data: any }) => void;
  postError?: Error;

  addEventListener(_type: string, listener: (event: { data: any }) => void) {
    this.listener = listener;
  }

  postMessage(message: unknown) {
    if (this.postError) throw this.postError;
    this.messages.push(message);
  }
}

function serviceWorkerContext(overrides: Record<string, unknown> = {}) {
  const listeners = new Map<string, (event: any) => void>();
  const channel = new TestBroadcastChannel();
  const self = {
    location: new URL("https://lush.local/"),
    clients: { claim: vi.fn().mockResolvedValue(undefined) },
    skipWaiting: vi.fn().mockResolvedValue(undefined),
    addEventListener: (type: string, listener: (event: any) => void) =>
      listeners.set(type, listener),
  };
  const context = vm.createContext({
    self,
    URL,
    Request,
    Response,
    Headers,
    Uint8Array,
    Map,
    Set,
    Promise,
    Object,
    decodeURIComponent,
    setTimeout,
    clearTimeout,
    crypto: { randomUUID: () => "handoff-id" },
    BroadcastChannel: class {
      constructor() {
        return channel;
      }
    },
    caches: {
      keys: vi.fn().mockResolvedValue([]),
      delete: vi.fn().mockResolvedValue(true),
      open: vi.fn(),
    },
    fetch: vi.fn(),
    ...overrides,
  });
  const source = readFileSync(new URL("../public/sw.js", import.meta.url), "utf8");
  vm.runInContext(source, context);
  return { context, channel, listeners };
}

describe("service worker", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  test("only decodes same-origin special URLs", () => {
    const { context } = serviceWorkerContext();
    context.input = new URL("https://lush.local/automerge%3Adoc");
    expect(vm.runInContext("specialURLFor(input)?.href", context)).toBe(
      "automerge:doc",
    );
    context.input = new URL("https://other.local/automerge%3Adoc");
    expect(vm.runInContext("specialURLFor(input)", context)).toBeUndefined();
    context.input = new URL("https://lush.local/%E0%A4%A");
    expect(vm.runInContext("specialURLFor(input)", context)).toBeUndefined();
  });

  test("bounds a missing handoff reply and clears pending state", async () => {
    vi.useFakeTimers();
    const fallback = new Response("fallback", { status: 200 });
    const fetch = vi.fn().mockResolvedValue(fallback);
    const { context, channel, listeners } = serviceWorkerContext({
      fetch,
      setTimeout,
      clearTimeout,
    });
    const request = new Request("https://lush.local/automerge%3Adoc");
    let resultPromise: Promise<Response> | undefined;
    listeners.get("fetch")!({
      request,
      respondWith: (value: Promise<Response>) => {
        resultPromise = value;
      },
    });
    await vi.advanceTimersByTimeAsync(0);
    expect(channel.messages).toHaveLength(1);
    expect(vm.runInContext("pendingHandoffs.size", context)).toBe(1);

    await vi.advanceTimersByTimeAsync(35_000);
    const result = await resultPromise!;

    expect(await result.text()).toBe("fallback");
    expect(fetch).toHaveBeenCalledOnce();
    expect(vm.runInContext("pendingHandoffs.size", context)).toBe(0);
    expect(vi.getTimerCount()).toBe(0);
    channel.listener!({ data: { type: "online" } });
    expect(channel.messages).toHaveLength(1);
  });

  test("clears pending state after a response", async () => {
    vi.useFakeTimers();
    const { context, channel } = serviceWorkerContext({ setTimeout, clearTimeout });
    context.request = new Request(
      "https://lush.local/automerge%3Adoc",
    );
    context.handoffURL = new URL("automerge:doc");

    const resultPromise = vm.runInContext(
      "serveHandoff(request, undefined, handoffURL, undefined)",
      context,
    ) as Promise<Response>;
    channel.listener!({
      data: {
        id: "handoff-id",
        type: "response",
        response: { status: 204, body: new Uint8Array(), headers: {} },
      },
    });
    const result = await resultPromise;

    expect(result.status).toBe(204);
    expect(vm.runInContext("pendingHandoffs.size", context)).toBe(0);
    expect(vi.getTimerCount()).toBe(0);
  });

  test("falls back when a handoff response is malformed", async () => {
    vi.useFakeTimers();
    const fallback = new Response("fallback", { status: 200 });
    const fetch = vi.fn().mockResolvedValue(fallback);
    const { context, channel } = serviceWorkerContext({
      fetch,
      setTimeout,
      clearTimeout,
    });
    context.request = new Request(
      "https://lush.local/automerge%3Adoc",
    );
    context.handoffURL = new URL("automerge:doc");

    const resultPromise = vm.runInContext(
      "serveHandoff(request, undefined, handoffURL, undefined)",
      context,
    ) as Promise<Response>;
    channel.listener!({ data: { id: "handoff-id", type: "response" } });
    const result = await resultPromise;

    expect(await result.text()).toBe("fallback");
    expect(fetch).toHaveBeenCalledOnce();
    expect(vm.runInContext("pendingHandoffs.size", context)).toBe(0);
    expect(vi.getTimerCount()).toBe(0);
  });

  test("falls back immediately when posting the handoff fails", async () => {
    vi.useFakeTimers();
    const fallback = new Response("fallback", { status: 200 });
    const fetch = vi.fn().mockResolvedValue(fallback);
    const { context, channel } = serviceWorkerContext({
      fetch,
      setTimeout,
      clearTimeout,
    });
    channel.postError = new Error("closed");
    context.request = new Request(
      "https://lush.local/automerge%3Adoc",
    );
    context.handoffURL = new URL("automerge:doc");

    const result = await (vm.runInContext(
      "serveHandoff(request, undefined, handoffURL, undefined)",
      context,
    ) as Promise<Response>);

    expect(await result.text()).toBe("fallback");
    expect(fetch).toHaveBeenCalledOnce();
    expect(vm.runInContext("pendingHandoffs.size", context)).toBe(0);
    expect(vi.getTimerCount()).toBe(0);
  });

  test("settles a cache acknowledgement with a missing entry", async () => {
    vi.useFakeTimers();
    const cache = { match: vi.fn().mockResolvedValue(undefined) };
    const { context, channel } = serviceWorkerContext({ setTimeout, clearTimeout });
    context.request = new Request(
      "https://lush.local/automerge%3Adoc",
    );
    context.handoffURL = new URL("automerge:doc");
    context.cache = cache;

    const resultPromise = vm.runInContext(
      "serveHandoff(request, cache, handoffURL, undefined)",
      context,
    ) as Promise<Response>;
    channel.listener!({ data: { id: "handoff-id", type: "cached" } });
    const result = await resultPromise;

    expect(result.type).toBe("error");
    expect(vm.runInContext("pendingHandoffs.size", context)).toBe(0);
    expect(vi.getTimerCount()).toBe(0);
  });

  test("caches opaque external responses", async () => {
    const put = vi.fn().mockResolvedValue(undefined);
    const cache = { match: vi.fn(), put, keys: vi.fn().mockResolvedValue([]) };
    const clone = { type: "opaque", status: 0 };
    const response = { type: "opaque", status: 0, clone: () => clone };
    const fetch = vi.fn().mockResolvedValue(response);
    const caches = { open: vi.fn().mockResolvedValue(cache) };
    const { context } = serviceWorkerContext({ fetch, caches });
    context.request = new Request("https://cdn.example/file");

    const result = await (vm.runInContext(
      "serveExternal(request)",
      context,
    ) as Promise<Response>);

    expect(result).toBe(response);
    expect(put).toHaveBeenCalledWith(context.request, clone);
  });

  test("trims external cache entries to its bound", async () => {
    const keys = Array.from(
      { length: 141 },
      (_, index) => new Request(`https://cdn.example/${index}`),
    );
    const remove = vi.fn().mockResolvedValue(true);
    const cache = {
      match: vi.fn(),
      put: vi.fn().mockResolvedValue(undefined),
      keys: vi.fn().mockResolvedValue(keys),
      delete: remove,
    };
    const response = new Response("ok", { status: 200 });
    const fetch = vi.fn().mockResolvedValue(response);
    const caches = { open: vi.fn().mockResolvedValue(cache) };
    const { context } = serviceWorkerContext({ fetch, caches });
    context.request = new Request("https://cdn.example/current");

    await vm.runInContext("serveExternal(request)", context);

    expect(remove).toHaveBeenCalledTimes(13);
    expect(remove.mock.calls.map(([value]) => value)).toEqual(keys.slice(0, 13));
  });

  test("uses cached external content when the network fails", async () => {
    const cached = new Response("cached", { status: 200 });
    const cache = {
      match: vi.fn().mockResolvedValue(cached),
      put: vi.fn(),
      keys: vi.fn(),
    };
    const fetch = vi.fn().mockRejectedValue(new Error("offline"));
    const caches = { open: vi.fn().mockResolvedValue(cache) };
    const { context } = serviceWorkerContext({ fetch, caches });
    context.request = new Request("https://cdn.example/file");

    const result = await (vm.runInContext(
      "serveExternal(request)",
      context,
    ) as Promise<Response>);

    expect(await result.text()).toBe("cached");
    expect(cache.put).not.toHaveBeenCalled();
  });
});
