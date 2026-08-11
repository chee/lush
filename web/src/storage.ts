import { fromBase64, toBase64 } from "./bytes";

export type StorageCall = (
  message: Record<string, unknown>,
) => Promise<Record<string, any> | undefined>;

// Storage lives in the app: reads and writes go over IPC to native files,
// and the first load of any doc falls through to the Rust core's own
// storage, so docs the app already has open with no network sync.
export class NativeStorageAdapter {
  static readonly chunkBytes = 512 * 1024;
  static readonly encodedChunkBytes =
    Math.ceil(NativeStorageAdapter.chunkBytes / 3) * 4;
  static readonly pageEntries = 32;

  readonly #call: StorageCall;

  constructor(call: StorageCall) {
    this.#call = call;
  }

  async load(key: string[]) {
    const result = await this.#call({ op: "loadStart", key });
    if (!result?.transfer) return undefined;
    const size = result.size;
    if (!Number.isSafeInteger(size) || size < 0) {
      throw new Error("storage load returned an invalid size");
    }
    const data = new Uint8Array(size);
    let offset = 0;
    try {
      while (offset < size) {
        const response = await this.#call({
          op: "loadChunk",
          transfer: result.transfer,
          offset,
        });
        if (typeof response?.binary !== "string") {
          throw new Error("storage load returned no data");
        }
        const chunk = fromBase64(response.binary);
        if (
          chunk.length === 0 ||
          chunk.length > NativeStorageAdapter.chunkBytes ||
          chunk.length > size - offset
        ) {
          throw new Error("storage load returned an invalid chunk");
        }
        data.set(chunk, offset);
        offset += chunk.length;
      }
      return data;
    } finally {
      await this.#call({ op: "loadEnd", transfer: result.transfer }).catch(
        () => {},
      );
    }
  }
  async save(key: string[], binary: Uint8Array) {
    const result = await this.#call({ op: "saveStart", key });
    if (typeof result?.transfer !== "string" || result.transfer === "") {
      throw new Error("storage save did not start");
    }
    let offset = 0;
    try {
      if (binary.length === 0) {
        await this.#call({
          op: "saveChunk",
          transfer: result.transfer,
          offset,
          binary: "",
          done: true,
        });
        return;
      }
      while (offset < binary.length) {
        const end = Math.min(
          offset + NativeStorageAdapter.chunkBytes,
          binary.length,
        );
        await this.#call({
          op: "saveChunk",
          transfer: result.transfer,
          offset,
          binary: toBase64(binary.subarray(offset, end)),
          done: end === binary.length,
        });
        offset = end;
      }
    } catch (error) {
      await this.#call({
        op: "saveCancel",
        transfer: result.transfer,
      }).catch(() => {});
      throw error;
    }
  }
  // One message per batch that fits the IPC budget; only a value too big for
  // a single message falls back to the chunked transfer.
  async saveBatch(entries: [string[], Uint8Array][]) {
    let batch: { key: string[]; binary: string }[] = [];
    let encoded = 0;
    const flush = async () => {
      if (batch.length === 0) return;
      const packed = batch;
      batch = [];
      encoded = 0;
      await this.#call({ op: "saveBatch", entries: packed });
    };
    for (const [key, binary] of entries) {
      if (binary.length > NativeStorageAdapter.chunkBytes) {
        await flush();
        await this.save(key, binary);
        continue;
      }
      const size = Math.ceil(binary.length / 3) * 4;
      if (
        batch.length === NativeStorageAdapter.pageEntries ||
        encoded + size > NativeStorageAdapter.encodedChunkBytes
      ) {
        await flush();
      }
      batch.push({ key, binary: toBase64(binary) });
      encoded += size;
    }
    await flush();
  }
  async remove(key: string[]) {
    await this.#call({ op: "remove", key });
  }
  async loadRange(keyPrefix: string[]) {
    const chunks: { key: string[]; data: Uint8Array }[] = [];
    let result = await this.#call({ op: "loadRangeStart", key: keyPrefix });
    const transfer = result?.transfer;
    if (typeof transfer !== "string" || transfer === "") {
      throw new Error("storage range did not start");
    }
    try {
      while (true) {
        const entries = result?.entries;
        if (
          result?.transfer !== transfer ||
          !Array.isArray(entries) ||
          entries.length > NativeStorageAdapter.pageEntries ||
          typeof result?.done !== "boolean" ||
          (!result.done && entries.length === 0)
        ) {
          throw new Error("storage range returned an invalid page");
        }
        // `count` is how many of the range's entries the page covers: a page
        // that carries fewer than it consumed has dropped chunks, and a range
        // that reads short presents as a document's whole history.
        if (result.count !== entries.length) {
          throw new Error("storage range returned a short page");
        }
        for (const entry of entries) {
          if (
            !entry ||
            !Array.isArray(entry.key) ||
            !entry.key.every((component: unknown) => typeof component === "string") ||
            !Number.isSafeInteger(entry.size) ||
            entry.size < 0 ||
            (entry.binary !== undefined && typeof entry.binary !== "string")
          ) {
            throw new Error("storage range returned an invalid entry");
          }
          const data =
            entry.binary === undefined
              ? await this.load(entry.key)
              : fromBase64(entry.binary);
          if (!data || data.length !== entry.size) {
            throw new Error("storage range entry changed while loading");
          }
          chunks.push({ key: entry.key, data });
        }
        if (result.done) return chunks;
        result = await this.#call({ op: "loadRangePage", transfer });
      }
    } finally {
      await this.#call({ op: "loadRangeEnd", transfer }).catch(() => {});
    }
  }
  async removeRange(keyPrefix: string[]) {
    await this.#call({ op: "removeRange", key: keyPrefix });
  }
}
