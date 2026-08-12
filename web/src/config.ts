import { MemorySigner } from "@automerge/automerge-subduction/slim";
import { hexToBytes } from "./bytes";
import type { PatchworkConfig } from "./types";

export const DEFAULT_ENDPOINT = "wss://subduction.sync.inkandswitch.com";

export function subductionEndpoints(config: PatchworkConfig): string[] {
  const endpoints = config.subductionEndpoints?.length
    ? config.subductionEndpoints
    : [config.publicEndpoint ?? DEFAULT_ENDPOINT];
  const local = (config.localWsPorts ?? []).map(
    (port) => `ws://127.0.0.1:${port}`,
  );
  return [...new Set([...endpoints, ...local])];
}

export function embedSubductionEndpoints(config: PatchworkConfig): string[] {
  return config.coreWsPort ? [`ws://127.0.0.1:${config.coreWsPort}`] : [];
}

export function configuredSigner(config: PatchworkConfig): MemorySigner {
  return config.signerSeedHex
    ? MemorySigner.fromBytes(hexToBytes(config.signerSeedHex))
    : new MemorySigner();
}
