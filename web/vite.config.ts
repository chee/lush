import patchwork from "@inkandswitch/patchwork/vite";
import { defineConfig } from "vite";
import { pkgBaseManifest } from "./vite/pkg-base-manifest";

export default defineConfig({
  base: "./",
  resolve: {
    // Everything resolves to the /slim entries; the host fetches and inits
    // the wasm itself in main.ts, so the auto-loading entries must never be
    // bundled. These aliases apply to patchwork()'s importmap chunks too, so
    // doc-served tools share the same initialized instances.
    alias: [
      {
        find: /^@automerge\/automerge$/,
        replacement: "@automerge/automerge/slim",
      },
      {
        find: /^@automerge\/automerge-repo$/,
        replacement: "@automerge/automerge-repo/slim",
      },
      {
        find: /^@automerge\/automerge-subduction$/,
        replacement: "@automerge/automerge-subduction/slim",
      },
    ],
  },
  build: {
    rollupOptions: {
      output: {
        // Keep each automerge package in one chunk; rollup otherwise splits
        // automerge-repo across chunks that import each other circularly.
        manualChunks(id) {
          const match = id.match(/node_modules\/(@automerge\/[^/]+)\//);
          if (match) return match[1].replace("/", "-");
        },
      },
    },
  },
  plugins: [
    patchwork({
      title: "Patchwork",
      html: false,
      icons: false,
      manifest: false,
      netlify: false,
      server: false,
      preview: false,
      static: [{ from: "@inkandswitch/patchwork-pkg-base", to: "/pkg-base" }],
      build: {
        outDir: "../PatchworkWeb.bundle",
        emptyOutDir: true,
        target: "esnext",
        modulePreload: false,
      },
    }),
    pkgBaseManifest(),
  ],
});
