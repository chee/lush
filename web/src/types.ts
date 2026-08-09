import type { AutomergeUrl } from "@automerge/automerge-repo/slim";

// The pushwork/patchwork "folder" shape (patchwork-folder).
export type DocLink = {
  name: string;
  type: string;
  url: AutomergeUrl;
  icon?: string;
};

export type FolderDoc = {
  "@patchwork": { type: "folder" };
  title: string;
  docs: DocLink[];
  lastSyncAt?: number;
};

export type PatchworkConfig = {
  publicEndpoint?: string;
  subductionEndpoints?: string[];
  localWsPorts?: number[];
  signerSeedHex?: string;
  accountUrl?: string;
  moduleUrls?: string[];
  accountModuleUrl?: string;
};

declare global {
  interface Window {
    __patchwork_CONFIG: PatchworkConfig;
    repo: unknown;
    Patchwork: unknown;
    patchworkReady: Promise<unknown>;
    patchwork: unknown;
    Automerge: unknown;
    AutomergeRepo: unknown;
    __patchworkOpenSettings?: () => void;
    setDoc?: (
      docUrl: string | null,
      toolId?: string | null,
      draftUrl?: string | null,
      checkoutUrl?: string | null,
      backingUrl?: string | null,
    ) => Promise<void>;
    setOverlay?: (docUrl: string, backingUrl: string | null) => void;
    setContextTool?: (
      toolId: string | null,
      docUrl?: string | null,
      checkoutUrl?: string | null,
      backingUrl?: string | null,
    ) => void;
    webkit?: {
      messageHandlers?: {
        patchworkReady?: {
          postMessage: (message: unknown) => void;
        };
        lush?: { postMessage: (message: unknown) => void };
        lusherror?: { postMessage: (message: unknown) => void };
        lushstorage?: { postMessage: (message: unknown) => Promise<unknown> };
      };
    };
    __patchworkResolve?: (path: string) => Promise<{
      status: number;
      mimeType: string;
      base64: string;
    }>;
  }
}
