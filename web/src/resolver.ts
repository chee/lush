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
import { toBase64 } from "./bytes";

const RESOLVE_TIMEOUT_MS = 20_000;

type ResolveResult = {
  status: number;
  mimeType: string;
  base64: string;
  immutable: boolean;
};
type CacheEntry = { mimeType: string; bytes: Uint8Array };

function text(status: number, message: string): ResolveResult {
  return {
    status,
    mimeType: "text/plain",
    base64: toBase64(new TextEncoder().encode(message)),
    immutable: false,
  };
}

// Port of patchwork's waitForHeads (bootloader/automerge-worker.ts), with a
// timeout in place of the handoff AbortSignal.
function waitForHeads(
  handle: DocHandle<unknown>,
  hexHeads: string[],
  signal: AbortSignal,
): Promise<boolean> {
  if (hasHeads(handle.doc(), hexHeads)) return Promise.resolve(true);
  if (signal.aborted) return Promise.resolve(false);
  return new Promise((resolve) => {
    let done = false;
    const finish = (found: boolean) => {
      if (done) return;
      done = true;
      handle.off("heads-changed", check);
      signal.removeEventListener("abort", abort);
      resolve(found);
    };
    const check = () => {
      try {
        if (!hasHeads(handle.doc(), hexHeads)) return;
      } catch {
        finish(false);
        return;
      }
      finish(true);
    };
    const abort = () => finish(false);
    handle.on("heads-changed", check);
    signal.addEventListener("abort", abort, { once: true });
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
    let settled = false;
    req.onupgradeneeded = () => req.result.createObjectStore(CACHE_STORE);
    req.onsuccess = () => {
      if (settled) {
        req.result.close();
        return;
      }
      settled = true;
      resolve(req.result);
    };
    req.onerror = () => {
      if (settled) return;
      settled = true;
      reject(req.error);
    };
    req.onblocked = () => {
      if (settled) return;
      settled = true;
      reject(new Error("resolve cache is blocked"));
    };
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
          const tx = d.transaction(CACHE_STORE, "readonly");
          const req = tx.objectStore(CACHE_STORE).get(key);
          req.onsuccess = () => resolve(req.result as CacheEntry | undefined);
          req.onerror = () => resolve(undefined);
          tx.onabort = () => resolve(undefined);
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
          tx.onabort = () => resolve();
        }),
    )
    .catch(() => {});
}

function urlPinned(url: AutomergeUrl): boolean {
  try {
    const { heads } = parseAutomergeUrl(url);
    return !!heads && heads.length > 0;
  } catch {
    return false;
  }
}

// Head-pinned URLs are content-addressed — safe to cache indefinitely.
export function isPinned(raw: string): boolean {
  try {
    const url = decodeURIComponent(raw.split("/")[0]) as AutomergeUrl;
    if (!isValidAutomergeUrl(url)) return false;
    return urlPinned(url);
  } catch {
    return false;
  }
}

// The JS half of PatchworkSchemeHandler: patchwork's resolveAutomergeUrl with the
// service-worker/SharedWorker handoff collapsed into one native round trip.
// `raw` is the URL path after patchwork://app/ — an encoded automerge: URL first,
// then the file path inside the folder doc. Scheme handlers can't redirect, so
// a headless URL is pinned to current heads and served directly.
export function installResolver(repo: Repo) {
  window.__patchworkResolve = async (raw: string): Promise<ResolveResult> => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), RESOLVE_TIMEOUT_MS);
    try {
      const [encoded, ...path] = raw.split("/");
      const maybeAutomergeUrl = decodeURIComponent(encoded) as AutomergeUrl;
      if (!isValidAutomergeUrl(maybeAutomergeUrl)) {
        return text(400, `invalid automerge url: ${maybeAutomergeUrl}`);
      }
      if (path.length && !path[path.length - 1]) path.pop();

      let { heads, hexHeads, documentId } =
        parseAutomergeUrl(maybeAutomergeUrl);
      const pinned = isPinned(raw);
      if (pinned) {
        const cached = await cacheGet(raw);
        if (cached) {
          return {
            status: 200,
            mimeType: cached.mimeType,
            base64: toBase64(cached.bytes),
            immutable: true,
          };
        }
      }

      const baseHandle = await repo.find(
        stringifyAutomergeUrl({ documentId }),
        { signal: controller.signal },
      );

      if (!heads) {
        heads = baseHandle.heads();
        hexHeads = undefined;
      } else if (
        !(await waitForHeads(baseHandle, hexHeads ?? [], controller.signal))
      ) {
        return text(
          504,
          `heads not found for ${maybeAutomergeUrl} within ${RESOLVE_TIMEOUT_MS}ms`,
        );
      }

      // A pinned folder can still link to headless children, whose bytes move
      // under us — the whole followed chain has to be pinned to be cacheable.
      let immutable = pinned;
      const resolvingRepo = {
        find: (url: AutomergeUrl) => {
          if (!urlPinned(url)) immutable = false;
          return repo.find(url, { signal: controller.signal });
        },
      } as unknown as Repo;
      const resolved = await resolvePath(
        resolvingRepo,
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

      if (immutable) {
        cachePut(raw, { mimeType: resolved.type, bytes });
      }

      return {
        status: 200,
        mimeType: resolved.type,
        base64: toBase64(bytes),
        immutable,
      };
    } catch (error) {
      if (controller.signal.aborted) {
        return text(
          504,
          `resolution timed out within ${RESOLVE_TIMEOUT_MS}ms`,
        );
      }
      return text(500, String(error));
    } finally {
      clearTimeout(timer);
    }
  };
}
