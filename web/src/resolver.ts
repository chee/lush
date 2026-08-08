import {
  isValidAutomergeUrl,
  parseAutomergeUrl,
  stringifyAutomergeUrl,
  type AutomergeUrl,
  type DocHandle,
  type Repo,
} from "@automerge/automerge-repo/slim";
import { hasHeads } from "@automerge/automerge/slim";
import { resolvePath } from "@inkandswitch/patchwork-filesystem";

const RESOLVE_TIMEOUT_MS = 20_000;

type ResolveResult = { status: number; mimeType: string; base64: string };
type CacheEntry = { mimeType: string; bytes: Uint8Array };

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return btoa(binary);
}

function text(status: number, message: string): ResolveResult {
  return {
    status,
    mimeType: "text/plain",
    base64: toBase64(new TextEncoder().encode(message)),
  };
}

// Port of patchwork's waitForHeads (bootloader/automerge-worker.ts), with a
// timeout in place of the handoff AbortSignal.
function waitForHeads(
  handle: DocHandle<unknown>,
  hexHeads: string[],
  timeoutMs: number,
): Promise<boolean> {
  if (hasHeads(handle.doc(), hexHeads)) return Promise.resolve(true);
  return new Promise((resolve) => {
    const cleanup = () => {
      handle.off("heads-changed", check);
      clearTimeout(timer);
    };
    const check = () => {
      if (!hasHeads(handle.doc(), hexHeads)) return;
      cleanup();
      resolve(true);
    };
    const timer = setTimeout(() => {
      cleanup();
      resolve(false);
    }, timeoutMs);
    handle.on("heads-changed", check);
    check();
  });
}

// IndexedDB cache for head-pinned (immutable) resolved content.
const CACHE_DB = "patchwork-resolve-cache";
const CACHE_STORE = "v1";

let _db: Promise<IDBDatabase> | undefined;

function resolveDB(): Promise<IDBDatabase> {
  return (_db ??= new Promise<IDBDatabase>((resolve, reject) => {
    const req = indexedDB.open(CACHE_DB, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(CACHE_STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  }).catch((e) => {
    _db = undefined;
    throw e;
  }));
}

function cacheGet(key: string): Promise<CacheEntry | undefined> {
  return resolveDB()
    .then(
      (d) =>
        new Promise<CacheEntry | undefined>((resolve) => {
          const req = d
            .transaction(CACHE_STORE, "readonly")
            .objectStore(CACHE_STORE)
            .get(key);
          req.onsuccess = () => resolve(req.result as CacheEntry | undefined);
          req.onerror = () => resolve(undefined);
        }),
    )
    .catch(() => undefined);
}

function cachePut(key: string, entry: CacheEntry): void {
  void resolveDB()
    .then(
      (d) =>
        new Promise<void>((resolve) => {
          const tx = d.transaction(CACHE_STORE, "readwrite");
          tx.objectStore(CACHE_STORE).put(entry, key);
          tx.oncomplete = () => resolve();
          tx.onerror = () => resolve();
        }),
    )
    .catch(() => {});
}

// The JS half of PatchworkSchemeHandler: patchwork's resolveAutomergeUrl with the
// service-worker/SharedWorker handoff collapsed into one native round trip.
// `raw` is the URL path after patchwork://app/ — an encoded automerge: URL first,
// then the file path inside the folder doc. Scheme handlers can't redirect, so
// a headless URL is pinned to current heads and served directly.
export function installResolver(repo: Repo) {
  window.__patchworkResolve = async (raw: string): Promise<ResolveResult> => {
    try {
      const [encoded, ...path] = raw.split("/");
      const maybeAutomergeUrl = decodeURIComponent(encoded) as AutomergeUrl;
      if (!isValidAutomergeUrl(maybeAutomergeUrl)) {
        return text(400, `invalid automerge url: ${maybeAutomergeUrl}`);
      }
      if (path.length && !path[path.length - 1]) path.pop();

      let { heads, hexHeads, documentId } =
        parseAutomergeUrl(maybeAutomergeUrl);

      // Head-pinned URLs are content-addressed — safe to cache indefinitely.
      const isPinned = !!heads && heads.length > 0;
      if (isPinned) {
        const cached = await cacheGet(raw);
        if (cached) {
          return {
            status: 200,
            mimeType: cached.mimeType,
            base64: toBase64(cached.bytes),
          };
        }
      }

      const baseHandle = await repo.find(stringifyAutomergeUrl({ documentId }));

      if (!heads) {
        heads = baseHandle.heads();
        hexHeads = undefined;
      } else if (
        !(await waitForHeads(baseHandle, hexHeads ?? [], RESOLVE_TIMEOUT_MS))
      ) {
        return text(
          504,
          `heads not found for ${maybeAutomergeUrl} within ${RESOLVE_TIMEOUT_MS}ms`,
        );
      }

      const resolved = await resolvePath(
        repo,
        baseHandle.view(heads),
        path.map(decodeURIComponent),
      );
      if (!resolved) {
        return text(
          404,
          `couldn't resolve ${path.join("/")} in ${maybeAutomergeUrl}`,
        );
      }

      const bytes =
        resolved.content instanceof Uint8Array
          ? resolved.content
          : new TextEncoder().encode(String(resolved.content));

      if (isPinned) {
        cachePut(raw, { mimeType: resolved.type, bytes });
      }

      return { status: 200, mimeType: resolved.type, base64: toBase64(bytes) };
    } catch (error) {
      return text(500, String(error));
    }
  };
}
