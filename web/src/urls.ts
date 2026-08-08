import type { AutomergeUrl, DocHandle } from "@automerge/automerge-repo/slim";

// Patchwork's replacement for patchwork's documentBaseOrigin(): custom-scheme
// URLs have a "null" origin, so build against the document base URL instead.
export function appBase(): string {
  return new URL("/", globalThis.document?.baseURI ?? globalThis.location.href)
    .href;
}

export function getImportableUrlFromAutomergeUrl(
  automergeUrl: AutomergeUrl | string,
  subpath?: string,
): string {
  const base = `${appBase()}${encodeURIComponent(automergeUrl)}/`;
  if (!subpath || subpath === ".") return base;
  return `${base}${subpath.replace(/^\.\//, "")}`;
}

/**
 * Importable URL from a DocHandle, pinned to the handle's latest heads so
 * module-cache keys refer to an exact version of the folder document.
 */
export function getImportableUrlFromDocHandle(
  handle: DocHandle<unknown>,
  subpath?: string,
): string {
  const url = handle.view(handle.heads()).url;
  return getImportableUrlFromAutomergeUrl(url, subpath);
}
