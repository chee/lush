import { defineConfig } from "vite";

// The embed shell the Lush WKWebView loads. Everything the shell HTML's
// importmap already serves out of /packages stays external, so the embed, the
// doc-served tools and <patchwork-view> all share one instance of each
// package — the same reason the main build routes them through the importmap.
const importmapped = [
  "@automerge/automerge/slim",
  "@automerge/automerge-repo/slim",
  "@automerge/automerge-subduction/slim",
  "@inkandswitch/patchwork-elements",
  "@inkandswitch/patchwork-filesystem",
  "@inkandswitch/patchwork-plugins",
  "@inkandswitch/patchwork-providers",
];

export default defineConfig({
  build: {
	 minify: true,
	 sourcemap: false,
    outDir: "../PatchworkWeb.bundle",
    emptyOutDir: false,
    target: "esnext",
    modulePreload: false,
    rollupOptions: {
      input: "src/embed.ts",
      external: importmapped,
      output: {
        format: "es",
        entryFileNames: "embed.js",
        codeSplitting: false,
      },
    },
  },
});
