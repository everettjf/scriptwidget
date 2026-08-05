import { defineConfig } from "vite";

// CodeMirror and Lezer rely on singleton identity for tags and facets.
// Keeping them out of Vite's dependency pre-bundling avoids duplicate module
// instances during development (which otherwise crash syntax highlighting).
export default defineConfig({
  base: "./",
  resolve: {
    dedupe: [
      "@codemirror/language",
      "@codemirror/state",
      "@codemirror/view",
      "@lezer/common",
      "@lezer/highlight",
    ],
  },
  optimizeDeps: {
    exclude: [
      "@codemirror/autocomplete",
      "@codemirror/commands",
      "@codemirror/lang-javascript",
      "@codemirror/language",
      "@codemirror/lint",
      "@codemirror/search",
      "@codemirror/state",
      "@codemirror/view",
      "@lezer/common",
      "@lezer/highlight",
      "@lezer/javascript",
      "@lezer/lr",
    ],
  },
});
