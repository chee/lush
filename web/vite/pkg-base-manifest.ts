import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { legacy, resolve as resolveExports } from "resolve.exports";
import type { Plugin } from "vite";

const require = createRequire(import.meta.url);
const conditions = ["patchwork", "browser", "import"];

// pkg-base's modules.json lists tool *directories*; over http the runtime
// probes each directory's package.json, but that path is http(s)-only, so on
// patchwork:// the entries must point straight at module files. This emits
// /modules.json with each entry resolved to its package entry point,
// alongside patchwork()'s static mount of the package at /pkg-base.
export function pkgBaseManifest(): Plugin {
  return {
    name: "patchwork-pkg-base-manifest",
    apply: "build",
    buildStart() {
      const root = dirname(
        require.resolve("@inkandswitch/patchwork-pkg-base/package.json"),
      );
      const manifest = JSON.parse(
        readFileSync(join(root, "modules.json"), "utf8"),
      );
      const modules: string[] = [];
      for (const entry of manifest.modules as string[]) {
        try {
          const pkg = JSON.parse(
            readFileSync(join(root, entry, "package.json"), "utf8"),
          );
          const resolved =
            resolveExports(pkg, ".", { conditions }) ??
            legacy(pkg, { fields: ["module", "main"] });
          const first = Array.isArray(resolved) ? resolved[0] : resolved;
          if (typeof first !== "string") continue;
          modules.push(
            `./pkg-base/${entry.replace(/^\.\//, "").replace(/\/?$/, "/")}${first.replace(/^\.\//, "")}`,
          );
        } catch {
          console.warn(
            `pkg-base-manifest: skipping ${entry} (no package.json)`,
          );
        }
      }
      modules.push("./modules/apple-tray.js");
      this.emitFile({
        type: "asset",
        fileName: "modules.json",
        source: JSON.stringify({ ...manifest, modules }, null, 1),
      });
    },
  };
}
