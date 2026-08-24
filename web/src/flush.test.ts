import { describe, expect, it, vi } from "vitest";
import { flushToServer, type FlushHandle, type FlushRepo } from "./flush";

const SERVER = "server-peer";

function makeHandle(overrides: Partial<FlushHandle> = {}): FlushHandle {
  return {
    documentId: "doc-1",
    isReady: () => true,
    heads: () => ["h1"],
    containsHeads: () => true,
    getSyncInfo: () => ({ lastHeads: ["h1"] }),
    ...overrides,
  };
}

function makeRepo(
  handles: FlushHandle[],
  overrides: Partial<FlushRepo> = {},
): FlushRepo & { listeners: Set<() => void>; resynced: string[] } {
  const listeners = new Set<() => void>();
  const resynced: string[] = [];
  return {
    handles: Object.fromEntries(
      handles.map((handle) => [handle.documentId, handle]),
    ),
    connectedSubductionPeerIds: async () => [SERVER],
    resyncSubduction: (documentId) => resynced.push(documentId),
    on: (_event, fn) => listeners.add(fn),
    off: (_event, fn) => listeners.delete(fn),
    listeners,
    resynced,
    ...overrides,
  };
}

describe("flushToServer", () => {
  it("resolves immediately when the server already holds our heads", async () => {
    const repo = makeRepo([makeHandle()]);
    await expect(flushToServer(repo, 3000)).resolves.toBe(true);
    expect(repo.listeners.size).toBe(0);
  });

  it("returns false when no server peer is connected", async () => {
    const repo = makeRepo([makeHandle()], {
      connectedSubductionPeerIds: async () => [],
    });
    await expect(flushToServer(repo, 3000)).resolves.toBe(false);
  });

  it("ignores handles that are not ready or empty", async () => {
    const repo = makeRepo([
      makeHandle({ documentId: "unready", isReady: () => false }),
      makeHandle({ documentId: "empty", heads: () => [] }),
    ]);
    await expect(flushToServer(repo, 3000)).resolves.toBe(true);
  });

  it("waits until the server advertises heads containing ours", async () => {
    vi.useFakeTimers();
    try {
      let advertised: string[] | undefined;
      const handle = makeHandle({
        getSyncInfo: () => (advertised ? { lastHeads: advertised } : undefined),
      });
      const repo = makeRepo([handle]);
      const result = flushToServer(repo, 3000);
      await vi.advanceTimersByTimeAsync(300);
      advertised = ["h1"];
      for (const fn of repo.listeners) fn();
      await vi.advanceTimersByTimeAsync(0);
      await expect(result).resolves.toBe(true);
      expect(repo.listeners.size).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it("requires pull completeness, not just an echo of our heads", async () => {
    vi.useFakeTimers();
    try {
      const handle = makeHandle({
        containsHeads: () => false,
        getSyncInfo: () => ({ lastHeads: ["h1", "server-only"] }),
      });
      const repo = makeRepo([handle]);
      const result = flushToServer(repo, 500);
      await vi.advanceTimersByTimeAsync(700);
      await expect(result).resolves.toBe(false);
    } finally {
      vi.useRealTimers();
    }
  });

  it("uses a remote-heads event that lands between polls", async () => {
    vi.useFakeTimers();
    try {
      let advertised: string[] | undefined;
      let fire = () => {};
      let polls = 0;
      const handle = makeHandle({
        getSyncInfo: () => {
          polls++;
          // The second poll runs in the gap between the two waits.
          if (polls === 2) {
            advertised = ["h1"];
            fire();
            return undefined;
          }
          return advertised ? { lastHeads: advertised } : undefined;
        },
      });
      const repo = makeRepo([handle]);
      fire = () => {
        for (const fn of repo.listeners) fn();
      };
      let settled = false;
      const result = flushToServer(repo, 3000).then((value) => {
        settled = true;
        return value;
      });

      await vi.advanceTimersByTimeAsync(100);

      expect(settled).toBe(true);
      await expect(result).resolves.toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });

  it("nudges resync once per stuck doc and times out false", async () => {
    vi.useFakeTimers();
    try {
      const handle = makeHandle({
        getSyncInfo: () => ({ lastHeads: ["stale"] }),
        containsHeads: () => true,
        heads: () => ["h2"],
      });
      const repo = makeRepo([handle]);
      const result = flushToServer(repo, 1000);
      await vi.advanceTimersByTimeAsync(1200);
      await expect(result).resolves.toBe(false);
      expect(repo.resynced).toEqual(["doc-1"]);
      expect(repo.listeners.size).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });
});
