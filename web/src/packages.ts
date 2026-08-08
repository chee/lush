import {
  isValidAutomergeUrl,
  parseAutomergeUrl,
  type AutomergeUrl,
  type Repo,
} from "@automerge/automerge-repo/slim";
import { resolve as resolveExports, legacy } from "resolve.exports";
import { getImportableUrlFromAutomergeUrl } from "./urls";

// Trimmed from patchwork's core/filesystem/src/packages.ts, pointed at
// Patchwork's url builders.
export const defaultImportConditions = ["patchwork", "browser", "import"];

// A failed import is memoized in the ES module map against its URL, so retry
// once under a distinct URL; heads-pinned URLs make this safe.
async function importModule(entryPointUrl: string) {
  try {
    return await import(/* @vite-ignore */ entryPointUrl);
  } catch (cause) {
    const retry = new URL(entryPointUrl);
    retry.searchParams.set("retry", "1");
    try {
      return await import(/* @vite-ignore */ retry.href);
    } catch {
      throw cause;
    }
  }
}

export async function importPackageFromFolderDocUrl(
  folderDocUrl: AutomergeUrl | string,
  subpath: string = ".",
  conditions: string[] = defaultImportConditions,
) {
  const base = getImportableUrlFromAutomergeUrl(folderDocUrl);
  const response = await fetch(`${base}package.json`);
  if (!response.ok) {
    if (subpath === ".") {
      throw new Error(`no package.json in folder doc at ${folderDocUrl}`);
    }
    return importModule(`${base}${subpath.replace(/^\.\//, "")}`);
  }
  const pkg = await response.json();
  const resolved =
    resolveExports(pkg, subpath, { conditions }) ??
    (subpath === "." ? legacy(pkg, { fields: ["module", "main"] }) : undefined);
  const first = Array.isArray(resolved) ? resolved[0] : resolved;
  const entry = typeof first === "string" ? first : undefined;
  if (!entry) {
    throw new Error(`no entry point for subpath "${subpath}" in package.json`);
  }
  return importModule(new URL(entry, base).href);
}

/**
 * Import a package living in an Automerge folder doc (or any plain URL).
 * Headless automerge: URLs are pinned to current heads first so the module
 * cache keys on an exact version.
 */
export async function makeImportPackage(repo: Repo) {
  return async function importPackage(
    url: string,
    subpath: string = ".",
    conditions: string[] = defaultImportConditions,
  ) {
    if (isValidAutomergeUrl(url)) {
      const { heads } = parseAutomergeUrl(url);
      if (!heads) {
        const handle = await repo.find(url);
        url = handle.view(handle.heads()).url;
      }
      return importPackageFromFolderDocUrl(url, subpath, conditions);
    }
    return importModule(url);
  };
}
