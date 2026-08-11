import {
  encodeHeads,
  generateAutomergeUrl,
  parseAutomergeUrl,
  stringifyAutomergeUrl,
} from "@automerge/automerge-repo/slim";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { toBase64 } from "./bytes";
import { installHandoffListener } from "./handoff";

class TestBroadcastChannel {
  static instances: TestBroadcastChannel[] = [];

  readonly messages: unknown[] = [];
  private listeners = new Set<(event: MessageEvent) => void>();

  constructor(readonly name: string) {
    TestBroadcastChannel.instances.push(this);
  }

  addEventListener(_type: string, listener: (event: MessageEvent) => void) {
    this.listeners.add(listener);
  }

  postMessage(message: unknown) {
    this.messages.push(message);
  }

  emit(data: unknown) {
    for (const listener of this.listeners) listener({ data } as MessageEvent);
  }
}

function request(id: string, raw: string) {
  return {
    id,
    type: "request",
    cachename: "handoff",
    request: {
      url: `https://lush.local/${raw}`,
      handoffURL: decodeURIComponent(raw),
      headers: {},
      method: "GET",
      referrer: "",
    },
  };
}

function pinnedRaw(): string {
  const { documentId } = parseAutomergeUrl(generateAutomergeUrl());
  const url = stringifyAutomergeUrl({
    documentId,
    heads: encodeHeads(["03".repeat(32)]),
  });
  return encodeURIComponent(url);
}

describe("handoff listener", () => {
  beforeEach(() => {
    TestBroadcastChannel.instances = [];
    vi.stubGlobal("BroadcastChannel", TestBroadcastChannel);
    vi.stubGlobal("window", {});
    vi.stubGlobal("caches", { open: vi.fn() });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  test("announces availability", () => {
    installHandoffListener();

    expect(TestBroadcastChannel.instances).toHaveLength(1);
    expect(TestBroadcastChannel.instances[0].messages).toEqual([
      { type: "online" },
    ]);
  });

  test("answers malformed requests instead of leaving them pending", async () => {
    installHandoffListener();
    const channel = TestBroadcastChannel.instances[0];

    for (let index = 0; index < 128; index++) {
      channel.emit({ id: `bad-${index}`, type: "request", request: null });
    }

    await vi.waitFor(() => expect(channel.messages).toHaveLength(129));
    for (const message of channel.messages.slice(1) as any[]) {
      expect(message.type).toBe("response");
      expect(message.response.status).toBe(500);
    }
  });

  test("answers distinct request failures exactly once", async () => {
    installHandoffListener();
    const channel = TestBroadcastChannel.instances[0];
    const url = encodeURIComponent(generateAutomergeUrl());
    const cases = [
      {
        id: "bad-url",
        type: "request",
        cachename: "handoff",
        request: {
          url: "%",
          handoffURL: generateAutomergeUrl(),
          headers: {},
          method: "GET",
          referrer: "",
        },
      },
      {
        ...request("bad-protocol", url),
        request: {
          ...request("bad-protocol", url).request,
          handoffURL: "https://lush.local/file",
        },
      },
      request("missing-resolver", url),
    ];

    for (const value of cases) channel.emit(value);

    await vi.waitFor(() => expect(channel.messages).toHaveLength(4));
    const replies = channel.messages.slice(1) as any[];
    expect(replies.map((reply) => reply.id)).toEqual([
      "bad-url",
      "bad-protocol",
      "missing-resolver",
    ]);
    expect(replies.every((reply) => reply.response.status === 500)).toBe(true);
  });

  test("returns an uncached response byte-for-byte", async () => {
    const body = Uint8Array.from([0, 1, 2, 127, 128, 254, 255]);
    window.__patchworkResolve = vi.fn().mockResolvedValue({
      status: 200,
      mimeType: "application/octet-stream",
      base64: toBase64(body),
    });
    installHandoffListener();
    const channel = TestBroadcastChannel.instances[0];
    channel.emit(request("binary", encodeURIComponent(generateAutomergeUrl())));

    await vi.waitFor(() => expect(channel.messages).toHaveLength(2));
    const reply = channel.messages[1] as any;
    expect(reply.type).toBe("response");
    expect(reply.response.status).toBe(200);
    expect(reply.response.body).toEqual(body);
  });

  test("reports resolver failures immediately", async () => {
    window.__patchworkResolve = vi.fn().mockRejectedValue(new Error("gone"));
    installHandoffListener();
    const channel = TestBroadcastChannel.instances[0];
    channel.emit(request("failed", encodeURIComponent(generateAutomergeUrl())));

    await vi.waitFor(() => expect(channel.messages).toHaveLength(2));
    const reply = channel.messages[1] as any;
    expect(reply.type).toBe("response");
    expect(reply.response.status).toBe(500);
  });

  test("reports invalid resolver base64 immediately", async () => {
    window.__patchworkResolve = vi.fn().mockResolvedValue({
      status: 200,
      mimeType: "application/octet-stream",
      base64: "%",
    });
    installHandoffListener();
    const channel = TestBroadcastChannel.instances[0];
    channel.emit(request("invalid-base64", encodeURIComponent(generateAutomergeUrl())));

    await vi.waitFor(() => expect(channel.messages).toHaveLength(2));
    const reply = channel.messages[1] as any;
    expect(reply.type).toBe("response");
    expect(reply.response.status).toBe(500);
  });

  test("stores pinned responses and acknowledges the cache write", async () => {
    const put = vi.fn().mockResolvedValue(undefined);
    vi.mocked(caches.open).mockResolvedValue({ put } as never);
    window.__patchworkResolve = vi.fn().mockResolvedValue({
      status: 204,
      mimeType: "text/plain",
      base64: "",
    });
    installHandoffListener();
    const channel = TestBroadcastChannel.instances[0];
    channel.emit(request("pinned", pinnedRaw()));

    await vi.waitFor(() => expect(channel.messages).toHaveLength(2));
    expect(put).toHaveBeenCalledOnce();
    expect(channel.messages[1]).toEqual({ id: "pinned", type: "cached" });
  });

  test("falls back to a direct response when a cache write fails", async () => {
    const put = vi.fn().mockRejectedValue(new Error("full"));
    vi.mocked(caches.open).mockResolvedValue({ put } as never);
    const body = Uint8Array.from([4, 5, 6]);
    window.__patchworkResolve = vi.fn().mockResolvedValue({
      status: 200,
      mimeType: "application/octet-stream",
      base64: toBase64(body),
    });
    installHandoffListener();
    const channel = TestBroadcastChannel.instances[0];
    channel.emit(request("cache-failed", pinnedRaw()));

    await vi.waitFor(() => expect(channel.messages).toHaveLength(2));
    const reply = channel.messages[1] as any;
    expect(reply.type).toBe("response");
    expect(reply.response.body).toEqual(body);
  });
});
