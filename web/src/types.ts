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
  localWsPort?: number;
  signerSeedHex?: string;
  accountUrl?: string;
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
    webkit?: {
      messageHandlers?: {
        patchworkReady?: {
          postMessage: (message: unknown) => void;
        };
      };
    };
    __patchworkResolve?: (path: string) => Promise<{
      status: number;
      mimeType: string;
      base64: string;
    }>;
  }
}
