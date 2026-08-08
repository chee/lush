import type { DocHandle, Repo } from "@automerge/automerge-repo/slim";
import { getRegistry } from "@inkandswitch/patchwork-plugins";
import type { AccountDoc, AppleConfigDoc } from "./account";
import type { DocLink, FolderDoc } from "./types";
import { makeImportPackage } from "./packages";
import {
  getImportableUrlFromAutomergeUrl,
  getImportableUrlFromDocHandle,
} from "./urls";

// pushwork's text detection (shapes/file.ts): valid utf-8 with no NUL and a
// byte-stable re-encoding is stored as a string, anything else as bytes.
function bytesToContent(bytes: Uint8Array): string | Uint8Array {
  if (bytes.includes(0)) return bytes;
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return bytes;
  }
  const reencoded = new TextEncoder().encode(text);
  if (reencoded.length !== bytes.length) return bytes;
  for (let i = 0; i < bytes.length; i++) {
    if (reencoded[i] !== bytes[i]) return bytes;
  }
  return text;
}

const APPLE_CONFIG_PROPERTIES = [
  {
    key: "defaultShortcutFolderUrl",
    label: "Default shortcut folder",
    type: "folder-url" as const,
  },
  {
    key: "remindersFolderUrl",
    label: "Reminders folder",
    type: "folder-url" as const,
  },
  {
    key: "createNewFolderUrl",
    label: "New document folder",
    type: "folder-url" as const,
  },
];

export function installPatchworkApi(repo: Repo) {
  // The account loads in the background after boot, so wait briefly for it
  // rather than failing an intent that fires right at launch.
  async function accountHandle(): Promise<DocHandle<AccountDoc> | undefined> {
    return (
      api.account ??
      (await Promise.race([
        api.accountReady,
        new Promise<undefined>((resolve) => setTimeout(resolve, 5000)),
      ]))
    );
  }

  let appleConfigCache: Promise<DocHandle<AppleConfigDoc>> | undefined;
  function appleConfigHandle(): Promise<DocHandle<AppleConfigDoc>> {
    appleConfigCache ??= (async () => {
      const account = await accountHandle();
      if (!account) throw new Error("no account is loaded yet");
      const existing = account.doc()?.tools?.apple;
      const handle = existing
        ? await repo.find<AppleConfigDoc>(existing)
        : repo.create<AppleConfigDoc>({
            "@patchwork": { type: "apple-config", title: "Apple app config" },
            properties: [],
          });
      // Add any properties this build knows about that the doc doesn't,
      // carrying over values from the old flat-field format.
      handle.change((d) => {
        if (!Array.isArray(d.properties)) d.properties = [];
        const flat = d as unknown as Record<string, string | null>;
        for (const p of APPLE_CONFIG_PROPERTIES) {
          if (!d.properties.some((x) => x.key === p.key)) {
            d.properties.push({ ...p, value: flat[p.key] ?? null });
          }
        }
      });
      if (!existing) {
        account.change((d) => {
          if (!d.tools) d.tools = {};
          d.tools.apple = handle.url;
        });
      }
      return handle;
    })();
    appleConfigCache.catch(() => {
      appleConfigCache = undefined;
    });
    return appleConfigCache;
  }

  // No folder url means the configured default shortcut folder, then the
  // account's root folder.
  async function targetFolderUrl(folderUrl?: string): Promise<string> {
    if (folderUrl) return folderUrl;
    const config = (await appleConfigHandle().catch(() => undefined))?.doc();
    const configured = config?.properties?.find(
      (p) => p.key === "defaultShortcutFolderUrl",
    )?.value;
    if (configured) return configured;
    const root = (await accountHandle())?.doc()?.rootFolderUrl;
    if (!root) {
      throw new Error(
        "no folder url given, and no account root folder is available (set up your account in the app)",
      );
    }
    return root;
  }

  const api = {
    account: undefined as DocHandle<AccountDoc> | undefined,
    accountReady: undefined as
      | Promise<DocHandle<AccountDoc> | undefined>
      | undefined,

    createDict(content: unknown): string {
      return repo.create(structuredClone(content) as Record<string, unknown>)
        .url;
    },

    async addToFolder(
      folderUrl: string | undefined,
      name: string,
      content: unknown,
      type?: string,
    ): Promise<string> {
      const folder = await repo.find<FolderDoc>(
        (await targetFolderUrl(folderUrl)) as never,
      );
      const value = structuredClone(content) as Record<string, unknown>;
      if (type) {
        const meta = (value["@patchwork"] ?? {}) as Record<string, unknown>;
        value["@patchwork"] = { ...meta, type };
      }
      const meta = value["@patchwork"] as { type?: string } | undefined;
      const handle = repo.create(value);
      const link: DocLink = {
        name,
        type: type ?? meta?.type ?? "dictionary",
        url: handle.url,
      };
      folder.change((d) => {
        if (!Array.isArray(d.docs)) d.docs = [];
        d.docs.push(link);
      });
      return handle.url;
    },

    async addFileToFolder(
      folderUrl: string | undefined,
      name: string,
      base64: string,
      mimeType: string,
    ): Promise<string> {
      const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
      const extension = name.includes(".") ? name.split(".").pop()! : "";
      const entry = {
        "@patchwork": { type: "file" },
        content: bytesToContent(bytes),
        extension,
        mimeType,
        name,
      };
      const folder = await repo.find<FolderDoc>(
        (await targetFolderUrl(folderUrl)) as never,
      );
      const handle = repo.create(entry);
      const link: DocLink = {
        name,
        type: extension || "file",
        url: handle.url,
      };
      folder.change((d) => {
        if (!Array.isArray(d.docs)) d.docs = [];
        d.docs.push(link);
      });
      return handle.url;
    },

    async listFolder(folderUrl?: string): Promise<DocLink[]> {
      const folder = await repo.find<FolderDoc>(
        (await targetFolderUrl(folderUrl)) as never,
      );
      return folder.doc()?.docs ?? [];
    },

    getImportableUrlFromAutomergeUrl,
    getImportableUrlFromDocHandle,

    async importPackage(url: string, subpath?: string): Promise<unknown> {
      const importer = await makeImportPackage(repo);
      return importer(url, subpath);
    },

    // Flat {key: value} view of the config properties.
    async appleConfig(): Promise<Record<string, string | null>> {
      const doc = (await appleConfigHandle()).doc();
      return Object.fromEntries(
        (doc?.properties ?? []).map((p) => [p.key, p.value ?? null]),
      );
    },

    async appleConfigProperties(): Promise<unknown[]> {
      const doc = (await appleConfigHandle()).doc();
      return structuredClone(doc?.properties ?? []);
    },

    async setAppleConfigValue(
      key: string,
      value: string | null,
    ): Promise<void> {
      const handle = await appleConfigHandle();
      handle.change((d) => {
        const property = d.properties.find((p) => p.key === key);
        if (!property) throw new Error(`no config property named "${key}"`);
        property.value = value;
      });
    },

    async listRootFolders(): Promise<DocLink[]> {
      const root = (await accountHandle())?.doc()?.rootFolderUrl;
      if (!root) return [];
      const folder = await repo.find<FolderDoc>(root);
      return structuredClone(
        (folder.doc()?.docs ?? []).filter((d) => d.type === "folder"),
      );
    },

    listDatatypes(): { id: string; name: string }[] {
      const entries = getRegistry("patchwork:datatype").all() as {
        id?: unknown;
        name?: unknown;
        unlisted?: boolean;
      }[];
      return entries
        .filter((d) => d.id != null && !d.unlisted)
        .map((d) => ({ id: String(d.id), name: String(d.name ?? d.id) }));
    },

    // Create a doc of a registered datatype, link it into the configured
    // create-new folder (falling back like everything else), and open it.
    async createNew(type: string, name: string): Promise<string> {
      const pw = window.patchwork as unknown as
        | {
            create?: (type: string) => Promise<unknown>;
            open?: (url: string) => void;
          }
        | undefined;
      if (!pw?.create) throw new Error("the patchwork frame isn't mounted yet");
      const created = (await pw.create(type)) as { url?: string } | string;
      const url = typeof created === "string" ? created : created?.url;
      if (!url) throw new Error(`creating a "${type}" returned no url`);
      const config = await api.appleConfig();
      const folder = await repo.find<FolderDoc>(
        (await targetFolderUrl(
          config.createNewFolderUrl ?? undefined,
        )) as never,
      );
      folder.change((d) => {
        if (!Array.isArray(d.docs)) d.docs = [];
        d.docs.push({ name, type, url: url as never });
      });
      pw.open?.(url);
      return url;
    },

    isConnected(): boolean {
      const r = repo as unknown as { isSubductionConnected?: () => boolean };
      return r.isSubductionConnected?.() ?? false;
    },

    async connectedPeerIds(): Promise<string[]> {
      const r = repo as unknown as {
        connectedSubductionPeerIds?: () => Promise<string[]>;
      };
      return (await r.connectedSubductionPeerIds?.()) ?? [];
    },
  };

  window.Patchwork = api;
  return api;
}

export type PatchworkApi = ReturnType<typeof installPatchworkApi>;
