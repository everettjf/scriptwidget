import { defineConfig } from "vite";
import { createHash } from "node:crypto";

function webStudioMock() {
  let content = `const widget = (\n  <VStack>\n    <Text text="Web Studio 1.0" />\n  </VStack>\n);\n`;
  let files = ["main.jsx", "lib/helper.js"];
  const revision = () => createHash("sha256").update(content).digest("hex");
  const json = (response, value, status = 200) => {
    response.statusCode = status;
    response.setHeader("Content-Type", "application/json");
    response.end(JSON.stringify(value));
  };
  return {
    name: "scriptwidget-web-studio-mock",
    configureServer(server) {
      server.middlewares.use((request, response, next) => {
        if (!request.url?.startsWith("/api/v1/")) { next(); return; }
        if (request.url === "/api/v1/pair" && request.method === "POST") { json(response, { token: "development-token" }); return; }
        if (request.url === "/api/v1/session") { json(response, { connected: true, leaseSeconds: 15, device: { name: "Development iPad", model: "iPad", system: "iPadOS" }, preview: { state: "idle" } }); return; }
        if (request.url === "/api/v1/packages") { json(response, { packages: [{ id: "Web Studio QA", name: "Web Studio QA", entry: "main.jsx", files }] }); return; }
        if (request.url.startsWith("/api/v1/events?")) { json(response, { events: [], nextSequence: 0 }); return; }
        if (request.url.startsWith("/api/v1/document?") && request.method === "GET") { json(response, { content, revision: revision(), readOnly: false, packageName: "Web Studio QA" }); return; }
        if (request.url.startsWith("/api/v1/document?") && request.method === "DELETE") {
          const path = new URL(request.url, "http://localhost").searchParams.get("path");
          if (path === "main.jsx") { json(response, { message: "The entry file cannot be deleted" }, 400); return; }
          files = files.filter((item) => item !== path);
          json(response, { deleted: true });
          return;
        }
        if (request.url === "/api/v1/document" && request.method === "POST") {
          const chunks = [];
          request.on("data", (chunk) => chunks.push(chunk));
          request.on("end", () => {
            const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
            if (files.includes(body.path)) { json(response, { message: "Choose a new path" }, 400); return; }
            files = [...files, body.path].sort();
            json(response, { path: body.path, revision: revision() }, 201);
          });
          return;
        }
        if (request.url === "/api/v1/document" && request.method === "PUT") {
          const chunks = [];
          request.on("data", (chunk) => chunks.push(chunk));
          request.on("end", () => {
            const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
            if (body.baseRevision !== revision()) { json(response, { message: "This document changed on the device.", currentContent: content, currentRevision: revision() }, 409); return; }
            content = body.content;
            json(response, { revision: revision(), preview: { state: "requested", package: body.package } });
          });
          return;
        }
        json(response, { message: "Unknown mock route" }, 404);
      });
    },
  };
}

// CodeMirror and Lezer rely on singleton identity for tags and facets.
// Keeping them out of Vite's dependency pre-bundling avoids duplicate module
// instances during development (which otherwise crash syntax highlighting).
export default defineConfig({
  base: "./",
  plugins: process.env.SCRIPTWIDGET_WEB_STUDIO_MOCK === "1" ? [webStudioMock()] : [],
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
