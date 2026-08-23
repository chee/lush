import { hasHeads } from "@automerge/automerge/slim";
import {
  encodeHeads,
  generateAutomergeUrl,
  parseAutomergeUrl,
  stringifyAutomergeUrl,
  type AutomergeUrl,
} from "@automerge/automerge-repo/slim";
import { resolvePath } from "@inkandswitch/patchwork-filesystem";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { fromBase64 } from "./bytes";
import { installResolver, isPinned } from "./resolver";

vi.mock("@automerge/automerge/slim", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@automerge/automerge/slim")>();
  return { ...actual, hasHeads: vi.fn(actual.hasHeads) };
});

vi.mock("@inkandswitch/patchwork-filesystem", () => ({
  resolvePath: vi.fn(),
}));

function pinnedUrl(): AutomergeUrl {
  const { documentId } = parseAutomergeUrl(generateAutomergeUrl());
  return stringifyAutomergeUrl({
    documentId,
    heads: encodeHeads(["01".repeat(32)]),
  });
}

function textOf(result: { base64: string }): string {
  return new TextDecoder().decode(fromBase64(result.base64));
}

describe("resolver", () => {
  beforeEach(() => {
    vi.stubGlobal("window", {});
    vi.mocked(hasHeads).mockReset();
    vi.mocked(resolvePath).mockReset();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  test("recognizes pinned URLs without throwing on hostile paths", () => {
    const pinned = pinnedUrl();
    expect(isPinned(encodeURIComponent(pinned))).toBe(true);
    expect(isPinned(generateAutomergeUrl())).toBe(false);

    const alphabet = "%/#?\u0000\ud800automerge:0123456789abcdef";
    let state = 7;
    for (let sample = 0; sample < 2_000; sample++) {
      let value = "";
      const length = sample % 97;
      for (let index = 0; index < length; index++) {
        state = (Math.imul(state, 1_103_515_245) + 12_345) >>> 0;
        value += alphabet[state % alphabet.length];
      }
      expect(() => isPinned(value)).not.toThrow();
    }
  });

  test("rejects invalid URLs before touching the repo", async () => {
    vi.useFakeTimers();
    const find = vi.fn();
    installResolver({ find } as never);

    const result = await window.__patchworkResolve!("%E0%A4%A");

    expect(result.status).toBe(500);
    expect(find).not.toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(0);
  });

  test("resolves a headless document and clears its deadline", async () => {
    vi.useFakeTimers();
    const url = generateAutomergeUrl();
    const handle = {
      heads: () => ["02".repeat(32)],
      view: vi.fn(() => ({ value: true })),
    };
    const find = vi.fn().mockResolvedValue(handle);
    vi.mocked(resolvePath).mockResolvedValue({
      type: "text/plain",
      content: "resolved",
    } as never);
    installResolver({ find } as never);

    const result = await window.__patchworkResolve!(encodeURIComponent(url));

    expect(result.status).toBe(200);
    expect(textOf(result)).toBe("resolved");
    expect(vi.getTimerCount()).toBe(0);
  });

  test("bounds a stalled repo lookup", async () => {
    vi.useFakeTimers();
    const url = generateAutomergeUrl();
    const find = vi.fn((_url, options: { signal: AbortSignal }) =>
      new Promise((_, reject) => {
        options.signal.addEventListener("abort", () => reject(new Error("aborted")), {
          once: true,
        });
      }),
    );
    installResolver({ find } as never);

    const resultPromise = window.__patchworkResolve!(encodeURIComponent(url));
    await vi.advanceTimersByTimeAsync(20_000);
    const result = await resultPromise;

    expect(result.status).toBe(504);
    expect(vi.getTimerCount()).toBe(0);
  });

  test("applies the same deadline to linked document lookups", async () => {
    vi.useFakeTimers();
    const baseUrl = generateAutomergeUrl();
    const linkedUrl = generateAutomergeUrl();
    const signals: AbortSignal[] = [];
    const handle = {
      heads: () => ["02".repeat(32)],
      view: () => ({}),
    };
    const find = vi
      .fn()
      .mockImplementationOnce((_url, options: { signal: AbortSignal }) => {
        signals.push(options.signal);
        return Promise.resolve(handle);
      })
      .mockImplementationOnce((_url, options: { signal: AbortSignal }) => {
        signals.push(options.signal);
        return new Promise((_, reject) => {
          options.signal.addEventListener(
            "abort",
            () => reject(new Error("aborted")),
            { once: true },
          );
        });
      });
    vi.mocked(resolvePath).mockImplementation(async (repo) => {
      await repo.find(linkedUrl);
      return undefined;
    });
    installResolver({ find } as never);

    const resultPromise = window.__patchworkResolve!(
      `${encodeURIComponent(baseUrl)}/linked`,
    );
    await vi.advanceTimersByTimeAsync(20_000);
    const result = await resultPromise;

    expect(result.status).toBe(504);
    expect(signals).toHaveLength(2);
    expect(signals[0]).toBe(signals[1]);
    expect(signals[0].aborted).toBe(true);
    expect(vi.getTimerCount()).toBe(0);
  });

  test("detaches the heads listener on timeout", async () => {
    vi.useFakeTimers();
    vi.mocked(hasHeads).mockReturnValue(false);
    const listeners = new Set<() => void>();
    const handle = {
      doc: () => ({}),
      on: vi.fn((_event, listener) => listeners.add(listener)),
      off: vi.fn((_event, listener) => listeners.delete(listener)),
      view: vi.fn(),
    };
    const find = vi.fn().mockResolvedValue(handle);
    installResolver({ find } as never);

    const resultPromise = window.__patchworkResolve!(
      encodeURIComponent(pinnedUrl()),
    );
    await vi.advanceTimersByTimeAsync(20_000);
    const result = await resultPromise;

    expect(result.status).toBe(504);
    expect(listeners.size).toBe(0);
    expect(handle.off).toHaveBeenCalledOnce();
    expect(vi.getTimerCount()).toBe(0);
  });

  test("detaches the heads listener when reading the document fails", async () => {
    vi.useFakeTimers();
    vi.mocked(hasHeads)
      .mockReturnValueOnce(false)
      .mockImplementationOnce(() => {
        throw new Error("closed");
      });
    let listener: (() => void) | undefined;
    const handle = {
      doc: () => ({}),
      on: vi.fn((_event, next) => {
        listener = next;
      }),
      off: vi.fn(),
      view: vi.fn(),
    };
    installResolver({ find: vi.fn().mockResolvedValue(handle) } as never);

    const resultPromise = window.__patchworkResolve!(
      encodeURIComponent(pinnedUrl()),
    );
    await vi.waitFor(() => expect(listener).toBeTypeOf("function"));
    listener!();
    const result = await resultPromise;

    expect(result.status).toBe(504);
    expect(handle.off).toHaveBeenCalledOnce();
    expect(vi.getTimerCount()).toBe(0);
  });

  test("won't call a chain through a headless link immutable", async () => {
    vi.mocked(hasHeads).mockReturnValue(true);
    const child = generateAutomergeUrl();
    const handle = { doc: () => ({}), view: () => ({}) };
    const find = vi.fn().mockResolvedValue(handle);
    vi.mocked(resolvePath).mockImplementation(async (repo) => {
      await repo.find(child);
      return { type: "text/plain", content: "child bytes" } as never;
    });
    installResolver({ find } as never);

    const result = await window.__patchworkResolve!(
      `${encodeURIComponent(pinnedUrl())}/child`,
    );

    expect(result.status).toBe(200);
    expect(textOf(result)).toBe("child bytes");
    expect(result.immutable).toBe(false);
  });

  test("keeps a fully head-pinned chain immutable", async () => {
    vi.mocked(hasHeads).mockReturnValue(true);
    const child = pinnedUrl();
    const handle = { doc: () => ({}), view: () => ({}) };
    const find = vi.fn().mockResolvedValue(handle);
    vi.mocked(resolvePath).mockImplementation(async (repo) => {
      await repo.find(child);
      return { type: "text/plain", content: "child bytes" } as never;
    });
    installResolver({ find } as never);

    const result = await window.__patchworkResolve!(
      `${encodeURIComponent(pinnedUrl())}/child`,
    );

    expect(result.status).toBe(200);
    expect(result.immutable).toBe(true);
  });

  test("never calls a headless base document immutable", async () => {
    const handle = {
      heads: () => ["02".repeat(32)],
      view: vi.fn(() => ({ value: true })),
    };
    vi.mocked(resolvePath).mockResolvedValue({
      type: "text/plain",
      content: "resolved",
    } as never);
    installResolver({ find: vi.fn().mockResolvedValue(handle) } as never);

    const result = await window.__patchworkResolve!(
      encodeURIComponent(generateAutomergeUrl()),
    );

    expect(result.status).toBe(200);
    expect(result.immutable).toBe(false);
  });

  test("recovers from a blocked cache open and an aborted read", async () => {
    vi.mocked(hasHeads).mockReturnValue(true);
    vi.mocked(resolvePath).mockResolvedValue(undefined);
    const requests: any[] = [];
    const firstDatabase = { close: vi.fn() };
    const secondDatabase = {
      close: vi.fn(),
      transaction: vi.fn(() => {
        const transaction: any = {
          objectStore: () => ({ get: () => ({ result: undefined }) }),
        };
        queueMicrotask(() => transaction.onabort?.());
        return transaction;
      }),
    };
    const databases = [firstDatabase, secondDatabase];
    const open = vi.fn(() => {
      const next: any = {
        result: databases[requests.length],
        error: null,
      };
      requests.push(next);
      return next;
    });
    vi.stubGlobal("indexedDB", { open });
    const handle = {
      doc: () => ({}),
      view: () => ({}),
    };
    installResolver({ find: vi.fn().mockResolvedValue(handle) } as never);
    const raw = encodeURIComponent(pinnedUrl());

    const blockedResult = window.__patchworkResolve!(raw);
    await vi.waitFor(() => expect(requests).toHaveLength(1));
    requests[0].onblocked();
    expect((await blockedResult).status).toBe(404);
    requests[0].onsuccess();
    expect(firstDatabase.close).toHaveBeenCalledOnce();

    const abortedReadResult = window.__patchworkResolve!(raw);
    await vi.waitFor(() => expect(requests).toHaveLength(2));
    requests[1].onsuccess();
    expect((await abortedReadResult).status).toBe(404);
    expect(secondDatabase.transaction).toHaveBeenCalledOnce();
  });
});
