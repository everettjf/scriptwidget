import assert from "node:assert/strict";
import test from "node:test";
import { StudioAPIError, WebStudioAPI } from "../src/webStudioAPI.js";

test("WebStudioAPI sends the current token and preserves caller headers", async () => {
  let captured;
  const client = new WebStudioAPI({
    token: () => "fresh-token",
    fetchImpl: async (path, options) => {
      captured = { path, options };
      return { ok: true, json: async () => ({ result: "ok" }) };
    },
  });
  assert.deepEqual(await client.request("/api/v1/session", { headers: { "X-Request-ID": "abc" } }), { result: "ok" });
  assert.equal(captured.options.headers["X-Studio-Token"], "fresh-token");
  assert.equal(captured.options.headers["X-Request-ID"], "abc");
});

test("WebStudioAPI exposes structured server conflicts", async () => {
  const client = new WebStudioAPI({
    fetchImpl: async () => ({ ok: false, status: 409, json: async () => ({ message: "Conflict", currentRevision: "r2" }) }),
  });
  await assert.rejects(client.request("/api/v1/document"), (error) => {
    assert.ok(error instanceof StudioAPIError);
    assert.equal(error.status, 409);
    assert.equal(error.body.currentRevision, "r2");
    return true;
  });
});

test("WebStudioAPI invalidates unauthorized sessions except failed pairing", async () => {
  let unauthorized = 0;
  const client = new WebStudioAPI({
    onUnauthorized: () => { unauthorized += 1; },
    fetchImpl: async () => ({ ok: false, status: 401, json: async () => ({}) }),
  });
  await assert.rejects(client.request("/api/v1/session"));
  await assert.rejects(client.request("/api/v1/pair"));
  assert.equal(unauthorized, 1);
});

test("WebStudioAPI tolerates an empty non-JSON success response", async () => {
  const client = new WebStudioAPI({
    fetchImpl: async () => ({ ok: true, json: async () => { throw new SyntaxError("empty"); } }),
  });
  assert.deepEqual(await client.request("/api/v1/session", { method: "DELETE" }), {});
});

test("WebStudioAPI reads authenticated preview blobs", async () => {
  let authorization;
  const expected = new Blob(["png"], { type: "image/png" });
  const client = new WebStudioAPI({
    token: () => "preview-token",
    fetchImpl: async (_, options) => {
      authorization = options.headers["X-Studio-Token"];
      return { ok: true, blob: async () => expected };
    },
  });
  assert.equal(await client.requestBlob("/api/v1/preview"), expected);
  assert.equal(authorization, "preview-token");
});
