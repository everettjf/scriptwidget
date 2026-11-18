import { readFile, writeFile } from "node:fs/promises";
import { scriptWidgetAPI as api } from "../src/scriptWidgetAPI.js";
import { dataAPICatalog } from "../src/dataAPICatalog.js";
import { platformCell, platformColumns, platformRow, platformSentence, platformSupport } from "../src/platformSupport.js";

const outputURL = new URL("../../../docs/scriptwidget-runtime-api.md", import.meta.url);

const lines = [
  "# ScriptWidget Runtime API",
  "",
  `> Generated from Studio's static API metadata (schema v${api.schemaVersion}, runtime ${api.runtimeVersion}). The native runtime switch is authoritative. Do not edit by hand.`,
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

// Which systems each API runs on, from platformSupport.js.

// Its Apple columns must say what the catalog says.
for (const group of [...new Set(dataAPICatalog.map((item) => item.group))]) {
  const row = platformRow(`$${group}`);
  if (!row) throw new Error(`platformSupport.js has no row for $${group}`);
  for (const item of dataAPICatalog.filter((entry) => entry.group === group)) {
    for (const id of ["ios", "macos"]) {
      if (item.platforms.includes(id) !== (row[id] !== false)) {
        throw new Error(`${item.id}: platformSupport.js and dataAPICatalog.js disagree about ${id}`);
      }
    }
  }
}

const code = (names) => names.map((name) => `\`${name}\``).join(", ");

const platformTable = [
  `| API | ${platformColumns.map((column) => column.title).join(" | ")} |`,
  `| --- | ${platformColumns.map(() => "---").join(" | ")} |`,
  ...platformSupport.map((row) => `| ${row.label ?? code(row.apis)} | ${platformColumns.map((column) => platformCell(row[column.id])).join(" | ")} |`),
];

function sentence(row) {
  const { yes, no } = platformSentence(row);
  return `${yes}.${no ? ` **Not on:** ${no}.` : ""}`;
}

// The note at the top of a page about one API or a few.
function runsOn(apis) {
  const rows = [...new Set(apis.map((name) => {
    const row = platformRow(name);
    if (!row) throw new Error(`platformSupport.js has no row for ${name}`);
    return row;
  }))];
  const link = "Details and limits: [Platform support](platform-support.md).";
  if (rows.length === 1) return [`> **Runs on:** ${sentence(rows[0])} ${link}`];
  return [
    "> **Runs on**",
    ">",
    ...rows.map((row) => `> - ${code(row.apis.filter((name) => apis.includes(name)))}: ${sentence(row)}`),
    ">",
    `> ${link}`,
  ];
}

// Replaces what is between the two markers of a hand-written page.
async function writeBetweenMarkers(file, content) {
  const url = new URL(`../../../docs/${file}`, import.meta.url);
  const text = await readFile(url, "utf8");
  const start = "<!-- platforms:start -->", end = "<!-- platforms:end -->";
  const from = text.indexOf(start), to = text.indexOf(end);
  if (from < 0 || to < from) throw new Error(`docs/${file} has no platforms markers`);
  await writeFile(url, `${text.slice(0, from + start.length)}\n${content.join("\n")}\n${text.slice(to)}`);
}

await writeBetweenMarkers("platform-support.md", platformTable);
await writeBetweenMarkers("runtime-api.md", platformTable);
for (const [file, apis] of Object.entries({
  "calendar-api.md": ["$calendar"],
  "file-api.md": ["$file"],
  "health-api.md": ["$health"],
  "http-response-api.md": ["$http"],
  "icloud-json-api.md": ["$icloud"],
  "location-api.md": ["$location"],
  "music-api.md": ["$music"],
  "photos-api.md": ["$photos"],
  "reminders-api.md": ["$reminders"],
  "services-api.md": ["$services"],
  "storage-api.md": ["$storage"],
  "system-services-api.md": ["$weather", "$alarms", "$documents", "$contacts", "$maps", "$home", "$notifications"],
})) {
  await writeBetweenMarkers(file, runsOn(apis));
}

const dataLines = [
  "# Data API capability catalog", "",
  "> Generated from `Editor/editorfe/src/dataAPICatalog.js` and `Editor/editorfe/src/platformSupport.js`. Native JSExport protocols remain authoritative. This catalog is descriptive and grants no permissions.", "",
  "This covers device, system, health, location, calendar, reminders, photos and connected-service data methods. Files, network, storage, rendering and runtime configuration retain their own contracts. Platforms list intended real-data support, not mocked browser execution; hardware and OS authorization still determine availability.", "",
  "Existing data-method return formats are unchanged. Present manifests now undergo package and minimum-version validation before execution. In particular, HealthKit does not expose individual read-denial status, and location cache presence is not proof that permission is still granted. Default mock values are illustrative, never measurements from the current device.", "",
  "## Which systems each API runs on", "",
  "\"Native platforms\" in the method table below means the Apple systems. Android, Windows and Linux run the same scripts on another engine; what they support is per API, not per method, and [Platform support](platform-support.md) explains each limit. An API a system lacks answers `false` from `isAvailable()` and rejects with `[unsupported_platform]`.", "",
  ...platformTable, "",
  "## Methods", "",
  "| API | Minimum native API | Native platforms | Execution | Authorization | Operation |", "| --- | --- | --- | --- | --- | --- |",
  ...dataAPICatalog.map((item) => `| \`${item.id}(${item.arguments.join(", ")})\` | ${item.minimumRuntimeVersion} | ${item.platforms.join(", ")} | ${item.asynchronous ? "Promise" : "Synchronous"} | ${item.authorization} | ${item.operation} |`), "",
];
for (const group of [...new Set(dataAPICatalog.map((item) => item.group))]) {
  const entries = dataAPICatalog.filter((item) => item.group === group);
  dataLines.push(`## ${group}`, "", entries[0].notes, "", `**Runs on:** ${sentence(platformRow(`$${group}`))}`, "");
  for (const entry of entries) {
    dataLines.push(`### \`${entry.id}\``, "", "Default editable preview sample:", "", "```json", JSON.stringify(entry.value, null, 2), "```", "");
  }
}
await writeFile(new URL("../../../docs/data-api-catalog.md", import.meta.url), `${dataLines.join("\n").trimEnd()}\n`);
