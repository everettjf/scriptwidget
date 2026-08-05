export const STUDIO_PROTOCOL_VERSION = 1;

export const StudioMessage = Object.freeze({
  ready: "studio.ready",
  documentOpen: "document.open",
  documentReplace: "document.replace",
  documentChanged: "document.changed",
  documentSave: "document.save",
  documentSetReadOnly: "document.setReadOnly",
  editorInsert: "editor.insert",
  editorFormat: "editor.format",
  editorSetTheme: "editor.setTheme",
  editorGetState: "editor.getState",
  diagnosticsPublish: "diagnostics.publish",
});

export function studioEnvelope(type, payload = {}, documentID = null) {
  return {
    protocolVersion: STUDIO_PROTOCOL_VERSION,
    type,
    documentID,
    payload,
  };
}

export function isStudioEnvelope(value) {
  return Boolean(
    value &&
      value.protocolVersion === STUDIO_PROTOCOL_VERSION &&
      typeof value.type === "string" &&
      value.payload &&
      typeof value.payload === "object"
  );
}
