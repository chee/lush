export type FlushHandle = {
  documentId: string;
  isReady: () => boolean;
  heads: () => string[];
  containsHeads: (heads: string[]) => boolean;
  getSyncInfo: (storageId: string) => { lastHeads: string[] } | undefined;
};

export type FlushRepo = {
  handles: Record<string, FlushHandle>;
  connectedSubductionPeerIds: () => Promise<string[]>;
  resyncSubduction: (documentId: string) => void;
  on: (event: "subduction-remote-heads", fn: () => void) => void;
  off: (event: "subduction-remote-heads", fn: () => void) => void;
};

function confirmed(handle: FlushHandle, storageId: string): boolean {
  const info = handle.getSyncInfo(storageId);
  if (!info?.lastHeads) return false;
  if (!handle.containsHeads(info.lastHeads)) return false;
  const advertised = new Set(info.lastHeads);
  return handle.heads().every((head) => advertised.has(head));
}

export async function flushToServer(
  repo: FlushRepo,
  timeoutMs = 3000,
): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  const [storageId] = await repo.connectedSubductionPeerIds();
  if (!storageId) return false;
  const pending = () =>
    Object.values(repo.handles).filter(
      (handle) =>
        handle.isReady() &&
        handle.heads().length > 0 &&
        !confirmed(handle, storageId),
    );
  if (pending().length === 0) return true;
  const nudged = new Set<string>();
  let wake = () => {};
  // Latched so an announcement landing between waits isn't lost to the gap.
  let signalled = false;
  const onHeads = () => {
    signalled = true;
    wake();
  };
  repo.on("subduction-remote-heads", onHeads);
  try {
    while (Date.now() < deadline) {
      if (!signalled) {
        await new Promise<void>((resolve) => {
          wake = resolve;
          setTimeout(resolve, 100);
        });
      }
      signalled = false;
      const rest = pending();
      if (rest.length === 0) return true;
      if (deadline - Date.now() < timeoutMs / 2) {
        for (const handle of rest) {
          if (nudged.has(handle.documentId)) continue;
          nudged.add(handle.documentId);
          repo.resyncSubduction(handle.documentId);
        }
      }
    }
    return pending().length === 0;
  } finally {
    repo.off("subduction-remote-heads", onHeads);
  }
}
