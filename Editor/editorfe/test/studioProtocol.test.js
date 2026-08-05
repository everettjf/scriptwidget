import test from "node:test";
import assert from "node:assert/strict";
import { STUDIO_PROTOCOL_VERSION, StudioMessage, isStudioEnvelope, studioEnvelope } from "../src/studioProtocol.js";

test("studio envelope includes version, document and payload", () => {
  const envelope = studioEnvelope(StudioMessage.documentOpen, { content: "hello" }, "main.jsx");
  assert.deepEqual(envelope, {
    protocolVersion: STUDIO_PROTOCOL_VERSION,
    type: "document.open",
    documentID: "main.jsx",
    payload: { content: "hello" },
  });
  assert.equal(isStudioEnvelope(envelope), true);
});

test("invalid or future envelopes are rejected", () => {
  assert.equal(isStudioEnvelope(null), false);
  assert.equal(isStudioEnvelope({ protocolVersion: 99, type: "document.open", payload: {} }), false);
  assert.equal(isStudioEnvelope({ protocolVersion: 1, payload: {} }), false);
});
