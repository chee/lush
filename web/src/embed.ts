import { initializeWasm } from "@automerge/automerge/slim";
// @ts-expect-error the wasm-bindgen default init is missing from the published typings
import initSubduction from "@automerge/automerge-subduction/slim";
import {
  Repo,
  isValidAutomergeUrl,
  parseAutomergeUrl,
  type AutomergeUrl,
  type PeerId,
} from "@automerge/automerge-repo/slim";
import { accept, registerRepoProviderElement } from "@inkandswitch/patchwork-providers";
import { registerPatchworkViewElement } from "@inkandswitch/patchwork-elements";
import { ModuleWatcher } from "@inkandswitch/patchwork-filesystem";
import {
  registerPlugins,
  unregisterPlugins,
  getSupportedToolsForType,
  getRegistry,
  createDocOfDatatype2,
} from "@inkandswitch/patchwork-plugins";
import * as plugins from "@inkandswitch/patchwork-plugins";
import { fromBase64, toBase64 } from "./bytes";
import { configuredSigner, subductionEndpoints } from "./config";
import { loadAccount } from "./account";
import { makeImportPackage } from "./packages";
import { installPatchworkApi } from "./patchwork-api";
import { installResolver } from "./resolver";
import type { PatchworkConfig } from "./types";

const reportError = (text: unknown) => {
  window.webkit?.messageHandlers?.lusherror?.postMessage(String(text));
};

window.addEventListener("error", (event) => {
  reportError(`${event.message} @ ${event.filename}:${event.lineno}`);
});
window.addEventListener("unhandledrejection", (event) => {
  reportError(`unhandled rejection: ${event.reason?.stack ?? event.reason}`);
});

const post = (message: unknown) => {
  window.webkit?.messageHandlers?.lush?.postMessage(message);
};

const status = (text: string) => {
  const el = document.getElementById("status");
  if (el) el.textContent = text;
};

// Storage lives in the app: reads and writes go over IPC to native files,
// and the first load of any doc falls through to the Rust core's own
// storage, so docs the app already has open with no network sync.
class NativeStorageAdapter {
  async #call(message: Record<string, unknown>) {
    try {
      return (await window.webkit?.messageHandlers?.lushstorage?.postMessage(
        message,
      )) as Record<string, any> | undefined;
    } catch (error) {
      reportError(`storage ${message.op} failed: ${error}`);
      throw error;
    }
  }
  async load(key: string[]) {
    const result = await this.#call({ op: "load", key });
    return result?.binary ? fromBase64(result.binary) : undefined;
  }
  async save(key: string[], binary: Uint8Array) {
    await this.#call({ op: "save", key, binary: toBase64(binary) });
  }
  async saveBatch(entries: [string[], Uint8Array][]) {
    await this.#call({
      op: "saveBatch",
      entries: entries.map(([key, binary]) => ({
        key,
        binary: toBase64(binary),
      })),
    });
  }
  async remove(key: string[]) {
    await this.#call({ op: "remove", key });
  }
  async loadRange(keyPrefix: string[]) {
    const result = await this.#call({ op: "loadRange", key: keyPrefix });
    return (result?.chunks ?? []).map(
      (chunk: { key: string[]; binary: string }) => ({
        key: chunk.key,
        data: fromBase64(chunk.binary),
      }),
    );
  }
  async removeRange(keyPrefix: string[]) {
    await this.#call({ op: "removeRange", key: keyPrefix });
  }
}

// The native half of the draft overlay: the app knows which document the
// view should really be reading — a draft's clone, pinned to the version the
// history inspector is scrubbed to — and says so directly, rather than
// through a doc the webview's repo would have to sync first.
//
// Answers `repo:handle-descriptor` for the mounted doc only (nested docs fall
// through to the draft overlay above us, which forks them lazily), and
// re-answers every live subscription on `set`, so OverlayRepo swaps the
// handle's backing in place: scrubbing rolls the tool back with no remount.
function docRemapper(docUrl: string, initial: string | null) {
  const element = document.createElement("div");
  element.style.display = "contents";
  const responders = new Set<() => void>();
  let backing = initial;

  const mounted = isValidAutomergeUrl(docUrl)
    ? parseAutomergeUrl(docUrl as AutomergeUrl).documentId
    : undefined;
  // Only the doc itself: a sub-document path under the same id is a different
  // document to the overlay repo, and we have no mapping for it.
  const isMountedDoc = (raw: unknown) => {
    if (typeof raw !== "string" || !mounted) return false;
    if (raw.slice("automerge:".length).includes("/")) return false;
    if (!isValidAutomergeUrl(raw)) return false;
    return parseAutomergeUrl(raw as AutomergeUrl).documentId === mounted;
  };

  element.addEventListener("patchwork:subscribe", (event: Event) => {
    const detail = (event as CustomEvent).detail;
    if (detail?.selector?.type !== "repo:handle-descriptor") return;
    if (!isMountedDoc(detail.selector.url)) return;
    accept<{ url: string; cloneUrl?: string }>(
      event as never,
      (respond: (descriptor: { url: string; cloneUrl?: string }) => void) => {
        const send = () =>
          respond(backing ? { url: docUrl, cloneUrl: backing } : { url: docUrl });
        responders.add(send);
        send();
        return () => {
          responders.delete(send);
        };
      },
    );
  });

  return {
    element,
    set(next: string | null) {
      if (next === backing) return;
      backing = next;
      for (const send of [...responders]) send();
    },
  };
}

// The one bit the host's activation machine needs: does anything in
// this embed actually scroll? If nothing does, wheel belongs to the tool.
function hasScrollableContent(root: Element): boolean {
  const walk = (el: Element | undefined, depth: number): boolean => {
    if (!el || depth > 10) return false;
    if (
      el.scrollHeight > el.clientHeight + 4 ||
      el.scrollWidth > el.clientWidth + 4
    ) {
      const style = getComputedStyle(el);
      if (/(auto|scroll)/.test(style.overflowY + style.overflowX)) return true;
    }
    const kids = [
      ...el.children,
      ...(el.shadowRoot ? el.shadowRoot.children : []),
    ];
    for (const child of kids) {
      if (walk(child, depth + 1)) return true;
    }
    return false;
  };
  return walk(root, 0);
}

async function boot() {
  const config: PatchworkConfig = window.__patchwork_CONFIG ?? {};
  status("loading wasm…");
  await Promise.all([
    initializeWasm(fetch("/automerge.wasm") as never),
    initSubduction({ module_or_path: fetch("/subduction.wasm") }),
  ]);

  const signer = configuredSigner(config);
  const repo = new Repo({
    storage: new NativeStorageAdapter(),
    signer,
    peerId: `lush-${Math.random().toString(36).slice(2, 10)}` as PeerId,
    enableRemoteHeadsGossiping: true,
    subductionWebsocketEndpoints: subductionEndpoints(config),
  } as never);
  window.repo = repo;
  installResolver(repo);
  const Patchwork = installPatchworkApi(repo);
  Patchwork.accountReady = isValidAutomergeUrl(config.accountUrl ?? "")
    ? loadAccount(repo, config.accountUrl as AutomergeUrl).then((account) => {
        Patchwork.account = account;
        return account;
      })
    : Promise.resolve(undefined);

  registerRepoProviderElement(repo);
  registerPatchworkViewElement({ repo });

  const importPackage = await makeImportPackage(repo);
  // Pin first so the plugins register under the same url the module cache
  // keyed on.
  const importToolPackage = async (toolUrl: AutomergeUrl) => {
    let url: string = toolUrl;
    if (!parseAutomergeUrl(toolUrl).heads) {
      const handle = await repo.find(toolUrl);
      url = handle.view(handle.heads()).url;
    }
    const mod = await importPackage(url);
    if (Array.isArray(mod?.plugins)) registerPlugins(mod.plugins, url);
    return mod;
  };

  // system is the bundled base package; account is the logged in user's
  // own module settings doc, so she gets the tools patchwork gives her
  const sources: Record<string, string> = { system: "/modules.json" };
  if (isValidAutomergeUrl(config.accountModuleUrl ?? "")) {
    sources.account = config.accountModuleUrl!;
  }
  for (const [index, moduleUrl] of (config.moduleUrls ?? []).entries()) {
    if (isValidAutomergeUrl(moduleUrl)) {
      sources[`user${index}`] = moduleUrl;
    }
  }
  const watcher = new ModuleWatcher(
    repo,
    sources,
    (name: string, mod: { plugins?: any[] }) => {
      if (Array.isArray(mod?.plugins)) registerPlugins(mod.plugins, name);
    },
    unregisterPlugins,
  );
  const toolsLoaded: Promise<unknown> = watcher.doneLoading.catch(
    (error: unknown) => {
      console.warn("lush: module loading failed", error);
    },
  );

  // Tool selection and the tools menu catch up in the background once
  // modules finish loading; the view element finds the doc on its own.
  const finishSetDoc = async (
    docUrl: string,
    toolId: string | null | undefined,
    view: Element,
  ) => {
    await toolsLoaded;
    let doc: any;
    try {
      const handle = await Promise.race([
        repo.find(docUrl as AutomergeUrl),
        new Promise<never>((_, reject) =>
          setTimeout(() => reject(new Error("timed out")), 15000),
        ),
      ]);
      doc = handle.doc();
    } catch (error) {
      console.warn("lush: could not load embedded doc", error);
    }
    const type = String(doc?.["@patchwork"]?.type ?? "");
    const listedToolsFor = (t: string) =>
      (getSupportedToolsForType(t) ?? []).filter((tool: any) => !tool.unlisted);
    const firstToolFor = (t: string) => listedToolsFor(t)[0]?.id;
    // A `*` tool renders anything and so says nothing about this datatype:
    // the doc's own suggested package is the better answer, and is worth
    // fetching until something names the type outright.
    const namedToolFor = (t: string) =>
      listedToolsFor(t).find(
        (tool: any) =>
          Array.isArray(tool.supportedDatatypes) &&
          tool.supportedDatatypes.includes(t),
      )?.id;
    if (!toolId) {
      toolId = namedToolFor(type);
      const suggested = doc?.["@patchwork"]?.suggestedImportUrl;
      if (!toolId && suggested && isValidAutomergeUrl(String(suggested))) {
        try {
          const mod = await importToolPackage(String(suggested) as AutomergeUrl);
          toolId =
            namedToolFor(type) ??
            (mod?.plugins ?? []).find(
              (plugin: any) => plugin?.type === "patchwork:tool",
            )?.id;
        } catch (error) {
          console.warn("lush: suggested tool import failed", error);
        }
      }
      toolId ??= firstToolFor(type);
      if (toolId && view.isConnected) view.setAttribute("tool-id", toolId);
    }
    if (!view.isConnected) return;
    const descriptors = getSupportedToolsForType(type) ?? [];
    const tools = descriptors
      .filter((tool: any) => !tool.unlisted)
      .map((tool: any) => ({ id: tool.id, name: tool.name ?? tool.id }));
    post({ kind: "tools", tools, current: toolId ?? null });
    const descriptor: any = descriptors.find((tool: any) => tool.id === toolId);
    if (typeof descriptor?.capturesPointer === "boolean") {
      post({ kind: "traits", capturesPointer: descriptor.capturesPointer });
    }
  };

  // Expose setDoc so native code can switch docs without reloading the
  // page. The view mounts immediately; nothing waits on module loading.
  // A draftUrl wraps the view in the draft overlay provider (inside
  // repo-provider, so descriptor requests reach the overlay first):
  // every doc resolved beneath it — the doc, its tool source, sub-docs —
  // lazily forks into that draft's clones, patchwork-identically.
  // checkoutUrl is the native-maintained CheckedOutDraft doc; a shim
  // around the tree answers the overlay's `draft:checked-out`
  // subscription with it, standing in for patchwork's draft-list
  // provider, so per-member checkpoint pins apply while scrubbing.
  window.setDoc = async (docUrl, toolId, draftUrl, checkoutUrl, backingUrl) => {
    if (!docUrl) {
      window.setOverlay = undefined;
      document.body.classList.remove("loading");
      document.body.replaceChildren();
      status("");
      return;
    }
    document.body.classList.add("loading");
    const view = document.createElement("patchwork-view");
    if (toolId) view.setAttribute("tool-id", toolId);
    view.setAttribute("doc-url", docUrl);
    const remapper = docRemapper(docUrl, backingUrl ?? null);
    remapper.element.appendChild(view);
    const provider = document.createElement("repo-provider");
    if (draftUrl || checkoutUrl) {
      const overlay = document.createElement("patchwork-view");
      overlay.setAttribute("component", "patchwork-draft-overlay-provider");
      if (draftUrl) overlay.setAttribute("url", draftUrl);
      overlay.appendChild(remapper.element);
      provider.appendChild(overlay);
    } else {
      provider.appendChild(remapper.element);
    }
    let mountRoot: Element = provider;
    if (checkoutUrl) {
      const shim = document.createElement("div");
      shim.style.display = "contents";
      shim.addEventListener("patchwork:subscribe", (event: Event) => {
        const detail = (event as CustomEvent).detail;
        if (detail?.selector?.type !== "draft:checked-out") return;
        event.stopPropagation();
        detail.port.postMessage({ type: "change", value: checkoutUrl });
      });
      shim.appendChild(provider);
      mountRoot = shim;
    }
    window.setOverlay = (url, next) => {
      if (url !== docUrl || !view.isConnected) return;
      remapper.set(next ?? null);
    };
    document.body.replaceChildren(mountRoot);
    // Pulse until the tool actually renders something (content may live in
    // a shadow root, so poll rather than observe). A superseded view stops
    // its timers without touching the class — the newer setDoc owns it.
    const stop = () => {
      clearInterval(poll);
      clearTimeout(cap);
    };
    const poll = setInterval(() => {
      if (!view.isConnected) return stop();
      if (view.childElementCount || view.shadowRoot?.childElementCount) {
        stop();
        document.body.classList.remove("loading");
        setTimeout(() => {
          if (!view.isConnected) return;
          post({
            kind: "traits",
            capturesPointer: !hasScrollableContent(view),
          });
        }, 400);
      }
    }, 100);
    const cap = setTimeout(() => {
      stop();
      if (view.isConnected) document.body.classList.remove("loading");
    }, 15000);
    finishSetDoc(docUrl, toolId, view).catch((error) => {
      console.warn("lush: tool setup failed", error);
    });
  };

  const runtime: any = {
    repo,
    hive: undefined,
    get account() {
      return Patchwork.account;
    },
    signer: {
      peerId: String(signer.peerId ?? ""),
      verifyingKey: String(signer.verifyingKey ?? ""),
    },
    packages: watcher,
    plugins,
    sw: {
      async connectClassicSync() {},
      async subscribeToRepoChannel() {
        return () => {};
      },
      async subscribeSyncState() {
        return () => {};
      },
    },
    async create(type: string, init?: (doc: unknown) => void) {
      const datatype = await getRegistry("patchwork:datatype").load(type);
      if (!datatype) {
        throw new Error(`patchwork.create: no datatype registered for "${type}"`);
      }
      return createDocOfDatatype2(datatype as never, repo, init as never, undefined);
    },
    open(url: AutomergeUrl, options: { tool?: string } = {}) {
      void window.setDoc?.(url, options.tool ?? null);
    },
    find<D>(url: AutomergeUrl) {
      return repo.find<D>(url);
    },
  };
  window.patchwork = runtime;

  const params = new URLSearchParams(location.search);
  if (params.get("mode") === "context") {
    installContextMode(params, toolsLoaded);
    return repo;
  }
  if (params.get("mode") === "picker") {
    // Render with whatever has registered so far rather than waiting on
    // stragglers; the paste field works regardless.
    await Promise.race([
      toolsLoaded,
      new Promise((resolve) => setTimeout(resolve, 1000)),
    ]);
    document.body.classList.remove("loading");
    renderPicker(repo);
    toolsLoaded.then(() => {
      const input = document.querySelector<HTMLInputElement>(".picker-paste input");
      if (!input || input.value === "") renderPicker(repo);
    });
    return repo;
  }
  const docUrl = params.get("doc-url");
  const toolId = params.get("tool-id");
  if (docUrl) {
    await window.setDoc(docUrl, toolId || null);
  } else {
    document.body.classList.remove("loading");
    status("");
  }
  return repo;
}

// Create-and-embed picker: list registered datatypes, create a doc of the
// chosen one (or take a pasted automerge: url), and hand the result to the
// native side through the "lush" message handler.
function renderPicker(repo: Repo) {
  const params = new URLSearchParams(location.search);
  const preferredType = params.get("type");
  const preferredTool = params.get("tool-id");
  const send = (url: string, tool?: string | null) => {
    post({ url, tool: tool ?? null });
  };
  const createDatatype = async (
    datatype: any,
    button: HTMLButtonElement | null,
  ) => {
    if (button) button.disabled = true;
    try {
      const loaded: any = await getRegistry("patchwork:datatype").load(
        datatype.id,
      );
      const handle = await createDocOfDatatype2(
        loaded,
        repo,
        undefined,
        undefined,
      );
      const url = handle?.url ?? String(handle);
      const tool =
        preferredTool ||
        (getSupportedToolsForType(datatype.id) ?? []).filter(
          (tool: any) => !tool.unlisted,
        )[0]?.id;
      send(url, tool);
    } catch (error) {
      status(String(error));
      if (button) button.disabled = false;
    }
  };
  const datatypes = (getRegistry("patchwork:datatype").all() ?? []).filter(
    (datatype: any) => !datatype.unlisted,
  );
  const root = document.createElement("div");
  root.className = "picker";

  const pasteRow = document.createElement("div");
  pasteRow.className = "picker-paste";
  const input = document.createElement("input");
  input.placeholder = "paste an automerge: url";
  const embedButton = document.createElement("button");
  embedButton.textContent = "Embed";
  const submitUrl = () => {
    const url = input.value.trim();
    if (url.startsWith("automerge:")) send(url, null);
  };
  embedButton.onclick = submitUrl;
  input.onkeydown = (event) => {
    if (event.key === "Enter") submitUrl();
  };
  pasteRow.append(input, embedButton);
  root.append(pasteRow);

  const heading = document.createElement("div");
  heading.className = "picker-heading";
  heading.textContent = "or create a new document";
  root.append(heading);

  for (const datatype of datatypes) {
    const button = document.createElement("button");
    button.className = "picker-type";
    button.textContent = datatype.name ?? datatype.id;
    button.onclick = () => createDatatype(datatype, button);
    root.append(button);
  }
  document.body.replaceChildren(root);
  if (preferredType) {
    const wanted = preferredType.toLowerCase();
    const datatype = datatypes.find(
      (datatype: any) =>
        datatype.id?.toLowerCase() === wanted ||
        datatype.name?.toLowerCase() === wanted,
    );
    if (datatype) createDatatype(datatype, null);
  }
}

// The context-tool sidebar: every `patchwork:component` tagged
// "context-tool" is offered to the native tab bar, and the chosen one is
// rendered bare — no bound doc — the way patchwork's own frame does it.
// Tools read the document they are about from a `patchwork:selected-doc`
// subscription, answered by patchwork's own selected-doc provider — which
// takes its selection from the location hash and from `open-document`
// events, so the note the inspector is open on is published as both.
function installContextMode(
  params: URLSearchParams,
  toolsLoaded: Promise<unknown>,
) {
  const accountUrl = params.get("account-url");
  let docUrl = params.get("doc-url");
  let checkoutUrl = params.get("checkout-url");
  let backingUrl = params.get("backing-url");
  const registry = getRegistry("patchwork:component");
  const publish = () => {
    const tools = (registry.all?.() ?? [])
      .filter((description: any) =>
        (description.tags ?? []).includes("context-tool"),
      )
      .map((description: any) => ({
        id: description.id,
        name: description.name || description.id,
      }))
      .sort((a: any, b: any) => a.name.localeCompare(b.name));
    post({ kind: "context-tools", tools });
  };

  window.setContextTool = (toolId, nextDocUrl, nextCheckoutUrl, nextBackingUrl) => {
    if (nextDocUrl !== undefined) docUrl = nextDocUrl;
    if (nextCheckoutUrl !== undefined) checkoutUrl = nextCheckoutUrl;
    if (nextBackingUrl !== undefined) backingUrl = nextBackingUrl;
    if (!toolId) {
      document.body.replaceChildren();
      return;
    }
    let root: HTMLElement = document.createElement("patchwork-view");
    root.setAttribute("component", toolId);
    const wrap = (component: string, url?: string | null) => {
      const wrapper = document.createElement("patchwork-view");
      wrapper.setAttribute("component", component);
      if (url) wrapper.setAttribute("doc-url", url);
      wrapper.appendChild(root);
      root = wrapper;
    };
    if (accountUrl) {
      wrap("patchwork-tool-storage-provider", accountUrl);
      wrap("patchwork-account-provider", accountUrl);
    }
    // the provider seeds its selection from `#doc=` when it loads, so set
    // the hash before mounting it; the event covers a provider that was
    // already listening
    if (docUrl) location.hash = `doc=${docUrl}`;
    wrap("patchwork-selected-doc-provider");
    const selectedDocProvider = root;
    // Same mapping the editor mounts: the tools speak about the origin url
    // while reading the checked-out draft's clone. The app says which doc
    // that is; the draft overlay handles everything nested under it.
    if (docUrl) {
      const remapper = docRemapper(docUrl, backingUrl);
      remapper.element.appendChild(root);
      root = remapper.element;
    }
    if (checkoutUrl) wrap("patchwork-draft-overlay-provider");
    const provider = document.createElement("repo-provider");
    provider.appendChild(root);
    const contextRoot = document.createElement("div");
    contextRoot.className = "context-root";
    if (checkoutUrl) {
      const url = checkoutUrl;
      contextRoot.addEventListener("patchwork:subscribe", (event: Event) => {
        const detail = (event as CustomEvent).detail;
        if (detail?.selector?.type !== "draft:checked-out") return;
        event.stopPropagation();
        detail.port.postMessage({ type: "change", value: url });
      });
    }
    contextRoot.appendChild(provider);
    document.body.replaceChildren(contextRoot);
    if (docUrl) {
      selectedDocProvider.dispatchEvent(
        new CustomEvent("patchwork:open-document", {
          detail: { url: docUrl, toolId: null },
        }),
      );
    }
  };

  registry.on?.("changed", publish);
  document.body.classList.remove("loading");
  status("");
  publish();
  toolsLoaded.then(publish);
}

window.patchworkReady = boot().catch((error) => {
  document.body.classList.remove("loading");
  status(String(error));
  throw error;
});
