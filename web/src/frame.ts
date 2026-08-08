import type {
  AutomergeUrl,
  DocHandle,
  Repo,
} from "@automerge/automerge-repo/slim";
import * as Automerge from "@automerge/automerge/slim";
import * as AutomergeRepo from "@automerge/automerge-repo/slim";
import { createRouter } from "@inkandswitch/patchwork";
import { registerPatchworkViewElement } from "@inkandswitch/patchwork-elements";
import { ModuleWatcher } from "@inkandswitch/patchwork-filesystem";
import * as plugins from "@inkandswitch/patchwork-plugins";
import {
  createDocOfDatatype2,
  getRegistry,
  registerPlugins,
  unregisterPlugins,
} from "@inkandswitch/patchwork-plugins";
import { registerRepoProviderElement } from "@inkandswitch/patchwork-providers";
import { accountFrameId, type AccountDoc } from "./account";

export type OpenOptions = { tool?: string; type?: string; title?: string };

/**
 * Load the module registry and mount `<patchwork-view>` inside a
 * `<repo-provider>` at the root, seeded with the account's chosen frame, then
 * hand routing to patchwork's real router. `window.patchwork` gets the same
 * shape `@inkandswitch/patchwork`'s setup() returns — `hive` is undefined
 * (Patchwork runs no keyhive) and `sw` is stubbed (the native scheme handler
 * stands in for the service worker).
 */
export async function mountFrame(
  repo: Repo,
  account: DocHandle<AccountDoc>,
  signer?: { peerId?: unknown; verifyingKey?: unknown },
): Promise<boolean> {
  const frameId = accountFrameId(account.doc());
  if (!frameId) return false;

  window.Automerge = Automerge;
  window.AutomergeRepo = AutomergeRepo;

  registerRepoProviderElement(repo as never);
  registerPatchworkViewElement({ repo });

  const sources: Record<string, string> = {
    // @inkandswitch/patchwork-pkg-base, bundled into the app and mounted at
    // /pkg-base; the manifest is rewritten to direct entry files at build
    system: "/modules.json",
  };
  const settingsUrl = account.doc()?.moduleSettingsUrl;
  if (settingsUrl) sources.user = settingsUrl;

  const watcher = new ModuleWatcher(
    repo,
    sources,
    (name, mod) => {
      const modPlugins = (mod as { plugins?: unknown })?.plugins;
      if (Array.isArray(modPlugins)) {
        registerPlugins(modPlugins, name);
      } else {
        console.warn(`module ${name} has no plugins array`);
      }
    },
    unregisterPlugins,
  );

  // Seed the root view before the router runs so mobileFrameId wins over the
  // router's own frameToolId-only seeding, then let the real router own hash
  // navigation and patchwork:open-document.
  const view = document.createElement("patchwork-view");
  view.setAttribute("tool-id", frameId);
  view.setAttribute("doc-url", account.url);
  const provider = document.createElement("repo-provider");
  provider.appendChild(view);
  document.body.style.margin = "0";
  document.body.replaceChildren(provider);

  const router = createRouter({
    rootElement: view,
    repo,
    accountDocHandle: account as never,
    siteTitle: "Patchwork",
  });
  await router.route();
  window.addEventListener("hashchange", () => void router.route());

  window.patchwork = {
    repo,
    hive: undefined,
    account,
    signer: signer && {
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

    async create<D>(type: string, init?: (doc: D) => void) {
      const datatype = await getRegistry("patchwork:datatype").load(type);
      if (!datatype) {
        throw new Error(
          `patchwork.create: no datatype registered for "${type}"`,
        );
      }
      return createDocOfDatatype2(datatype as never, repo, init, undefined);
    },
    open(url: AutomergeUrl, options: OpenOptions = {}) {
      const dispatch = () =>
        view.dispatchEvent(
          new CustomEvent("patchwork:open-document", {
            detail: {
              url,
              toolId: options.tool,
              type: options.type,
              title: options.title,
            },
          }),
        );
      void watcher.doneLoading.then(dispatch, dispatch);
    },
  };
  return true;
}
