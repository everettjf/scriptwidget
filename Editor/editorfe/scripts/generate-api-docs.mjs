import { readFile, writeFile } from "node:fs/promises";

const schemaURL = new URL("../../../Shared/ScriptWidgetRuntime/ScriptWidgetAPI.json", import.meta.url);
const outputURL = new URL("../../../docs/scriptwidget-runtime-api.md", import.meta.url);
const api = JSON.parse(await readFile(schemaURL, "utf8"));

const lines = [
  "# ScriptWidget Runtime API",
  "",
  `> Generated from \`ScriptWidgetAPI.json\` schema v${api.schemaVersion}, runtime ${api.runtimeVersion}. Do not edit by hand.`,
  "",
  "## Components",
  "",
];

for (const [name, component] of Object.entries(api.components)) {
  lines.push(`### \`<${name}>\``, "", component.documentation, "");
  const properties = { ...api.globalProperties, ...(component.properties ?? {}) };
  lines.push("| Property | Type | Required | Notes |", "| --- | --- | --- | --- |");
  for (const [propertyName, property] of Object.entries(properties)) {
    const notes = [property.documentation, property.values?.length ? `Values: ${property.values.map((value) => `\`${value}\``).join(", ")}` : "", property.deprecated ? `Deprecated: ${property.deprecated}` : ""].filter(Boolean).join(" ");
    lines.push(`| \`${propertyName}\` | \`${property.type}\` | ${property.required ? "Yes" : "No"} | ${notes} |`);
  }
  lines.push("");
}

lines.push("## Runtime functions", "");
for (const [name, definition] of Object.entries(api.functions)) {
  lines.push(`- \`${name}\`: ${definition.documentation}`);
}
lines.push("", "## Environment values", "", ...api.environmentValues.map((name) => `- \`${name}\``), "");

await writeFile(outputURL, `${lines.join("\n")}\n`);
