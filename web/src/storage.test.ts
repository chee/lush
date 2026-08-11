import { describe, expect, test, vi } from "vitest";
import { NativeStorageAdapter } from "./storage";
import { fromBase64, toBase64 } from "./bytes";

const ipcBytes = 512 * 1024;
const pageEntries = 32;

// Every op NativeWebStorage.handle answers, in lush/PatchworkView.swift.
const nativeOps = new Set([
  "loadStart",
  "loadChunk",
  "loadEnd",
  "saveStart",
  "saveChunk",
  "saveCancel",
  "saveBatch",
  "remove",
  "removeRange",
  "loadRangeStart",
  "loadRangePage",
  "loadRangeEnd",
]);

// The native admission control: over the ceiling a caller waits for a slot
// and nothing live is ever evicted, but the wait is bounded so a slot lost
// with a torn-down page fails one op instead of every op after it.
class Slots {
  used = 0;
  peak = 0;
  private waiting = new Set<(granted: boolean) => void>();
  constructor(
    private readonly limit: number,
    private readonly wait = Infinity,
  ) {}
  async acquire() {
    if (this.used < this.limit) {
      this.used += 1;
      this.peak = Math.max(this.peak, this.used);
      return true;
    }
    return await new Promise<boolean>((resolve) => {
      this.waiting.add(resolve);
      if (this.wait === Infinity) return;
      setTimeout(() => {
        if (this.waiting.delete(resolve)) resolve(false);
      }, this.wait);
    });
  }
  release() {
    for (const resolve of this.waiting) {
      this.waiting.delete(resolve);
      resolve(true);
      return;
    }
    if (this.used > 0) this.used -= 1;
  }
}

class FakeNative {
  files = new Map<string, Uint8Array>();
  ops: string[] = [];
  transferSlots: Slots;
  rangeSlots: Slots;
  private loads = new Map<string, { data: Uint8Array; offset: number; owner: string }>();
  private saves = new Map<
    string,
    { key: string[]; parts: Uint8Array[]; offset: number; owner: string }
  >();
  private ranges = new Map<string, { keys: string[][]; offset: number; owner: string }>();
  private nextToken = 0;

  constructor(transferLimit: number, rangeLimit: number, slotWait = Infinity) {
    this.transferSlots = new Slots(transferLimit, slotWait);
    this.rangeSlots = new Slots(rangeLimit, slotWait);
  }

  token() {
    this.nextToken += 1;
    return `t${this.nextToken}`;
  }

  // The scheduled reaper: a page that went away without ending its transfers
  // holds nothing, whether or not any of its ops ever come back.
  teardown(owner: string) {
    for (const [token, transfer] of this.loads) {
      if (transfer.owner !== owner) continue;
      this.loads.delete(token);
      this.transferSlots.release();
    }
    for (const [token, transfer] of this.saves) {
      if (transfer.owner !== owner) continue;
      this.saves.delete(token);
      this.transferSlots.release();
    }
    for (const [token, transfer] of this.ranges) {
      if (transfer.owner !== owner) continue;
      this.ranges.delete(token);
      this.rangeSlots.release();
    }
  }

  callFor(owner: string) {
    return (message: Record<string, any>) => this.receive(message, owner);
  }

  call = (message: Record<string, any>) => this.receive(message, "page");

  private receive = async (
    message: Record<string, any>,
    owner: string,
  ): Promise<Record<string, any> | undefined> => {
    const op = String(message.op);
    this.ops.push(op);
    expect(nativeOps).toContain(op);
    await Promise.resolve();
    switch (op) {
      case "loadStart": {
        if (!(await this.transferSlots.acquire())) {
          throw new Error("loadStart failed: storage is busy");
        }
        const data = this.files.get(message.key.join("/"));
        if (!data) {
          this.transferSlots.release();
          return {};
        }
        const token = this.token();
        this.loads.set(token, { data, offset: 0, owner });
        return { transfer: token, size: data.length };
      }
      case "loadChunk": {
        const transfer = this.loads.get(message.transfer);
        if (!transfer || transfer.offset !== message.offset) {
          throw new Error("invalid load offset");
        }
        const end = Math.min(transfer.offset + ipcBytes, transfer.data.length);
        const slice = transfer.data.subarray(transfer.offset, end);
        transfer.offset = end;
        if (end === transfer.data.length) {
          this.loads.delete(message.transfer);
          this.transferSlots.release();
        }
        return { binary: toBase64(slice) };
      }
      case "loadEnd": {
        if (this.loads.delete(message.transfer)) this.transferSlots.release();
        return {};
      }
      case "saveStart": {
        if (!(await this.transferSlots.acquire())) {
          throw new Error("saveStart failed: storage is busy");
        }
        const token = this.token();
        this.saves.set(token, { key: message.key, parts: [], offset: 0, owner });
        return { transfer: token };
      }
      case "saveChunk": {
        const transfer = this.saves.get(message.transfer);
        if (!transfer || transfer.offset !== message.offset) {
          throw new Error("invalid save offset");
        }
        const part = fromBase64(message.binary);
        transfer.parts.push(part);
        transfer.offset += part.length;
        if (message.done) {
          const whole = new Uint8Array(transfer.offset);
          let at = 0;
          for (const part of transfer.parts) {
            whole.set(part, at);
            at += part.length;
          }
          this.files.set(transfer.key.join("/"), whole);
          this.saves.delete(message.transfer);
          this.transferSlots.release();
        }
        return {};
      }
      case "saveCancel": {
        if (this.saves.delete(message.transfer)) this.transferSlots.release();
        return {};
      }
      case "saveBatch": {
        for (const entry of message.entries) {
          this.files.set(entry.key.join("/"), fromBase64(entry.binary));
        }
        return {};
      }
      case "remove": {
        this.files.delete(message.key.join("/"));
        return {};
      }
      case "removeRange": {
        const prefix = message.key.join("/");
        for (const key of [...this.files.keys()]) {
          if (key.startsWith(`${prefix}/`)) this.files.delete(key);
        }
        return {};
      }
      case "loadRangeStart": {
        if (!(await this.rangeSlots.acquire())) {
          throw new Error("loadRangeStart failed: storage is busy");
        }
        const prefix = message.key.join("/");
        const keys = [...this.files.keys()]
          .filter((key) => key.startsWith(`${prefix}/`))
          .sort()
          .map((key) => key.split("/"));
        const token = this.token();
        this.ranges.set(token, { keys, offset: 0, owner });
        return this.page(token);
      }
      case "loadRangePage":
        return this.page(message.transfer);
      case "loadRangeEnd": {
        if (this.ranges.delete(message.transfer)) this.rangeSlots.release();
        return {};
      }
    }
    throw new Error(`unknown storage op ${op}`);
  };

  // A page carries the bytes of every entry that fits the IPC budget; an
  // entry too big for a message is listed with a size only, and the adapter
  // fetches it with a nested chunked load.
  private page(token: string) {
    const transfer = this.ranges.get(token);
    if (!transfer) throw new Error("invalid range transfer");
    const entries: Record<string, unknown>[] = [];
    const from = transfer.offset;
    let inline = 0;
    while (transfer.offset < transfer.keys.length && entries.length < pageEntries) {
      const key = transfer.keys[transfer.offset];
      const data = this.files.get(key.join("/"))!;
      const fits = data.length <= ipcBytes - inline;
      if (!fits && entries.length > 0) break;
      transfer.offset += 1;
      const entry: Record<string, unknown> = { key, size: data.length };
      if (fits) {
        entry.binary = toBase64(data);
        inline += data.length;
      }
      entries.push(entry);
    }
    const done = transfer.offset === transfer.keys.length;
    if (done) {
      this.ranges.delete(token);
      this.rangeSlots.release();
    }
    return { transfer: token, entries, count: transfer.offset - from, done };
  }
}

const tick = async () => {
  for (let step = 0; step < 20; step++) await Promise.resolve();
};

const bytes = (length: number, seed: number) =>
  Uint8Array.from({ length }, (_, index) => (index * 31 + seed) % 251);

const same = (a: Uint8Array | undefined, b: Uint8Array | undefined) => {
  if (!a || !b || a.length !== b.length) return false;
  for (let index = 0; index < a.length; index++) {
    if (a[index] !== b[index]) return false;
  }
  return true;
};

describe("NativeStorageAdapter", () => {
  test("round trips values larger than one message", async () => {
    const native = new FakeNative(4, 2);
    const storage = new NativeStorageAdapter(native.call);
    const value = bytes(ipcBytes * 2 + 17, 3);
    await storage.save(["doc", "snapshot"], value);
    expect(same(await storage.load(["doc", "snapshot"]), value)).toBe(true);
    expect(native.ops.filter((op) => op === "saveChunk").length).toBe(3);
  });

  test("saveBatch splits into messages that fit the budget", async () => {
    const native = new FakeNative(4, 2);
    const storage = new NativeStorageAdapter(native.call);
    const entries: [string[], Uint8Array][] = Array.from(
      { length: 70 },
      (_, index) => [["doc", "incremental", `c${index}`], bytes(64, index)],
    );
    entries.push([["doc", "incremental", "big"], bytes(ipcBytes + 5, 9)]);
    await storage.saveBatch(entries);
    for (const [key, value] of entries) {
      expect(same(await storage.load(key), value)).toBe(true);
    }
    expect(native.ops.filter((op) => op === "saveBatch").length).toBe(3);
  });

  test("concurrent loadRanges past the ceiling all complete", async () => {
    const native = new FakeNative(4, 2);
    const storage = new NativeStorageAdapter(native.call);
    const expected = new Map<string, Uint8Array>();
    for (let index = 0; index < 40; index++) {
      const value = bytes(64, index);
      expected.set(`doc/incremental/c${index}`, value);
      native.files.set(`doc/incremental/c${index}`, value);
    }
    // Bigger than one message: the page lists it without bytes and the
    // adapter loads it separately, holding its range slot while it does.
    const big = bytes(ipcBytes + 11, 7);
    expected.set("doc/incremental/zbig", big);
    native.files.set("doc/incremental/zbig", big);

    const results = await Promise.all(
      Array.from({ length: 12 }, () => storage.loadRange(["doc", "incremental"])),
    );
    for (const chunks of results) {
      expect(chunks.length).toBe(expected.size);
      for (const chunk of chunks) {
        expect(same(chunk.data, expected.get(chunk.key.join("/")))).toBe(true);
      }
    }
    expect(native.rangeSlots.peak).toBe(2);
    expect(native.rangeSlots.used).toBe(0);
    expect(native.transferSlots.used).toBe(0);
  });

  // A range that reads short is treated as a document's whole history: the
  // next compaction writes a snapshot from it and removes the incrementals
  // it never saw. A page must never present as complete.
  test("a page that drops an entry fails the range", async () => {
    const native = new FakeNative(4, 2);
    for (let index = 0; index < 5; index++) {
      native.files.set(`doc/incremental/c${index}`, bytes(64, index));
    }
    const dropping = new NativeStorageAdapter(async (message) => {
      const result = await native.call(message);
      if (message.op !== "loadRangeStart" && message.op !== "loadRangePage") {
        return result;
      }
      return { ...result, entries: result!.entries.slice(1) };
    });
    await expect(dropping.loadRange(["doc", "incremental"])).rejects.toThrow(
      "short page",
    );
    expect(native.rangeSlots.used).toBe(0);
  });

  test("an entry the app cannot read fails the range", async () => {
    const native = new FakeNative(4, 2);
    for (let index = 0; index < 5; index++) {
      native.files.set(`doc/incremental/c${index}`, bytes(64, index));
    }
    const failing = new NativeStorageAdapter((message) => {
      if (message.op === "loadRangeStart") {
        throw new Error("loadRangeStart failed: storage value changed while loading");
      }
      return native.call(message);
    });
    await expect(failing.loadRange(["doc", "incremental"])).rejects.toThrow(
      "storage value changed while loading",
    );
    expect(native.rangeSlots.used).toBe(0);
  });

  // A webview can be torn down mid-boot: its loadRangeEnd never runs and its
  // entries are orphaned. The pool must come back without another op from
  // that page, or every later page waits on slots nobody holds.
  test("a page abandoned mid-transfer does not keep its slots", async () => {
    const native = new FakeNative(4, 2);
    for (let index = 0; index < 40; index++) {
      native.files.set(`doc/incremental/c${index}`, bytes(64, index));
    }
    let stalled = 0;
    const abandoned = new NativeStorageAdapter((message) => {
      if (message.op === "loadRangeStart") return native.callFor("gone")(message);
      stalled += 1;
      return new Promise<Record<string, any>>(() => {});
    });
    const dropped = [
      abandoned.loadRange(["doc", "incremental"]),
      abandoned.loadRange(["doc", "incremental"]),
    ];
    dropped.forEach((promise) => promise.catch(() => {}));
    await tick();
    expect(stalled).toBe(2);
    expect(native.rangeSlots.used).toBe(2);

    const live = new NativeStorageAdapter(native.callFor("live"));
    let settled = false;
    const pending = live.loadRange(["doc", "incremental"]).then((chunks) => {
      settled = true;
      return chunks;
    });
    await tick();
    expect(settled).toBe(false);

    native.teardown("gone");
    expect((await pending).length).toBe(40);
    expect(native.rangeSlots.used).toBe(0);
  });

  test("a slot that never comes back fails one op, not the next one", async () => {
    vi.useFakeTimers();
    try {
      const native = new FakeNative(4, 1, 1000);
      for (let index = 0; index < 40; index++) {
        native.files.set(`doc/incremental/c${index}`, bytes(64, index));
      }
      const abandoned = new NativeStorageAdapter((message) => {
        if (message.op === "loadRangeStart") return native.callFor("gone")(message);
        return new Promise<Record<string, any>>(() => {});
      });
      abandoned.loadRange(["doc", "incremental"]).catch(() => {});
      await vi.advanceTimersByTimeAsync(1);

      const live = new NativeStorageAdapter(native.call);
      const refused = live.loadRange(["doc", "incremental"]);
      const failure = expect(refused).rejects.toThrow("storage is busy");
      await vi.advanceTimersByTimeAsync(1000);
      await failure;

      native.teardown("gone");
      const chunks = await live.loadRange(["doc", "incremental"]);
      expect(chunks.length).toBe(40);
    } finally {
      vi.useRealTimers();
    }
  });

  test("concurrent loads and saves past the ceiling all complete", async () => {
    const native = new FakeNative(4, 2);
    const storage = new NativeStorageAdapter(native.call);
    const values = Array.from({ length: 30 }, (_, index) =>
      bytes(index === 0 ? ipcBytes + 3 : 128, index),
    );
    await Promise.all(
      values.map((value, index) => storage.save(["doc", `v${index}`], value)),
    );
    const loaded = await Promise.all(
      values.map((_, index) => storage.load(["doc", `v${index}`])),
    );
    expect(loaded.every((data, index) => same(data, values[index]))).toBe(true);
    expect(native.transferSlots.peak).toBe(4);
    expect(native.transferSlots.used).toBe(0);
  });
});
