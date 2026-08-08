import "@inkandswitch/patchwork/global.css";

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch(console.warn);
}
import { initializeWasm } from "@automerge/automerge/slim";
// @ts-expect-error initSync is a wasm-bindgen helper missing from the published typings
import { initSync as initSubductionSync } from "@automerge/automerge-subduction/slim";
import { MemorySigner } from "@automerge/automerge-subduction/slim";
import { Repo, type PeerId } from "@automerge/automerge-repo/slim";
import { IndexedDBStorageAdapter } from "@automerge/automerge-repo-storage-indexeddb";
import { accountFrameId, ensureAccountUrl, loadAccount } from "./account";
import { installPatchworkApi } from "./patchwork-api";
import { mountFrame } from "./frame";
import { installResolver } from "./resolver";
import { installSettings } from "./settings";
import { installHandoffListener } from "./handoff";
import type { PatchworkConfig } from "./types";

const DEFAULT_ENDPOINT = "wss://subduction.sync.inkandswitch.com";

function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

function show(id: string, text: string, ok?: boolean) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = text;
  if (ok !== undefined) el.className = ok ? "ok" : "bad";
}

function configuredSubductionEndpoints(config: PatchworkConfig): string[] {
  const endpoints = config.subductionEndpoints?.length
    ? config.subductionEndpoints
    : [config.publicEndpoint ?? DEFAULT_ENDPOINT];
  const withLocal = [...endpoints];
  if (config.localWsPort) {
    withLocal.push(`ws://127.0.0.1:${config.localWsPort}`);
  }
  return [...new Set(withLocal)];
}

function notifyNativeReady(error?: unknown) {
  window.webkit?.messageHandlers?.patchworkReady?.postMessage(
    error ? { error: String(error) } : { ok: true },
  );
}

async function boot() {
  const config: PatchworkConfig = window.__patchwork_CONFIG ?? {};

  const [amWasm, subWasm] = await Promise.all([
    fetch("/automerge.wasm").then((r) => r.arrayBuffer()),
    fetch("/subduction.wasm").then((r) => r.arrayBuffer()),
  ]);
  initSubductionSync(new Uint8Array(subWasm));
  await initializeWasm(new Uint8Array(amWasm));

  const signer = config.signerSeedHex
    ? MemorySigner.fromBytes(hexToBytes(config.signerSeedHex))
    : new MemorySigner();

  const endpoints = configuredSubductionEndpoints(config);

  const repo = new Repo({
    storage: new IndexedDBStorageAdapter(),
    signer,
    peerId: `patchwork-${Math.random().toString(36).slice(2, 10)}` as PeerId,
    enableRemoteHeadsGossiping: true,
    subductionWebsocketEndpoints: endpoints,
  } as never);

  window.repo = repo;
  installResolver(repo);
  installHandoffListener();
  const Patchwork = installPatchworkApi(repo);
  installSettings();
  show("repo-state", "ready", true);

  const updateConnection = async () => {
    try {
      const connected = Patchwork.isConnected();
      show(
        "connection",
        connected ? `connected (${endpoints.join(", ")})` : "disconnected",
        connected,
      );
      show("peers", (await Patchwork.connectedPeerIds()).join(", ") || "—");
    } catch (error) {
      show("connection", String(error), false);
    }
  };
  updateConnection();
  setInterval(updateConnection, 2000);
  (repo as unknown as { on?: (e: string, f: () => void) => void }).on?.(
    "subduction-connection",
    updateConnection,
  );

  // Non-blocking: intents only need the repo; the account gate can sit open.
  Patchwork.accountReady = (async () => {
    try {
      const accountUrl = await ensureAccountUrl(config.accountUrl);
      show("account", accountUrl, true);
      show("frame", "fetching account doc…");
      const slow = setTimeout(() => {
        show(
          "frame",
          "still waiting for the account doc — no connected peer has it yet. on a new device, add a peer (or sync the account to the public server) and this will pick up automatically",
          false,
        );
      }, 10_000);
      const account = await loadAccount(repo, accountUrl);
      clearTimeout(slow);
      Patchwork.account = account;
      Patchwork.appleConfig().catch(console.warn);
      const frameId = accountFrameId(account.doc());
      show("frame", frameId ?? "none set on account", !!frameId);
      mountFrame(repo, account, signer).catch((error) => {
        show("frame", `${frameId}: ${error}`, false);
      });
      return account;
    } catch (error) {
      show("account", String(error), false);
      return undefined;
    }
  })();

  return repo;
}

window.patchworkReady = boot()
  .then((repo) => {
    notifyNativeReady();
    return repo;
  })
  .catch((error) => {
    show("repo-state", String(error), false);
    notifyNativeReady(error);
    throw error;
  });
