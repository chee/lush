import {
  isValidAutomergeUrl,
  type AutomergeUrl,
  type DocHandle,
  type Repo,
} from "@automerge/automerge-repo/slim";

// Patchwork account doc, as far as Patchwork cares (core/plugins/src/account.ts).
export type AccountDoc = {
  mobileFrameId?: string;
  frameToolId?: string;
  rootFolderUrl?: AutomergeUrl;
  moduleSettingsUrl?: AutomergeUrl;
  contactUrl?: AutomergeUrl;
  tools?: { apple?: AutomergeUrl };
};

// Settings for the native app, linked from the account at tools.apple.
// Properties are self-describing so a settings UI can render them generically.
export type AppleConfigProperty = {
  key: string;
  label: string;
  type: "folder-url";
  value: string | null;
};

export type AppleConfigDoc = {
  "@patchwork": { type: string; title: string };
  properties: AppleConfigProperty[];
};

export function accountFrameId(
  doc: AccountDoc | undefined,
): string | undefined {
  return doc?.mobileFrameId ?? doc?.frameToolId;
}

/** `account:name/DocumentId` → `automerge:DocumentId`; raw automerge: URLs pass through. */
export function parseAccountInput(input: string): AutomergeUrl {
  const match = /^account:[^/]+\/([A-Za-z0-9]+)$/.exec(input);
  const url = match ? `automerge:${match[1]}` : input;
  if (!isValidAutomergeUrl(url)) {
    throw new Error(`not a valid account url: ${input}`);
  }
  return url;
}

/** Shows the account gate until a valid account URL is saved natively. */
export function ensureAccountUrl(
  configured: string | undefined,
): Promise<AutomergeUrl> {
  if (configured && isValidAutomergeUrl(configured)) {
    return Promise.resolve(configured);
  }
  const gate = document.getElementById("account-gate")!;
  const form = document.getElementById("account-form") as HTMLFormElement;
  const input = document.getElementById("account-input") as HTMLInputElement;
  const error = document.getElementById("account-error")!;
  gate.hidden = false;
  return new Promise((resolve) => {
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      error.textContent = "";
      try {
        const url = parseAccountInput(input.value.trim());
        const response = await fetch(
          `/__account/set?url=${encodeURIComponent(url)}`,
        );
        if (!response.ok) throw new Error(await response.text());
        gate.hidden = true;
        resolve(url);
      } catch (err) {
        error.textContent = String(err);
      }
    });
  });
}

export function loadAccount(
  repo: Repo,
  url: AutomergeUrl,
): Promise<DocHandle<AccountDoc>> {
  return repo.find<AccountDoc>(url);
}
