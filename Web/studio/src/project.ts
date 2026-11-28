import { defaultFixtures } from "./mockData.ts";
export { defaultFixtures } from "./mockData.ts";
// Project helpers shared by the Studio UI and its tests. No DOM access.
import { decodeManifest, legacyManifest, newProjectFiles, validateManifest } from "../../preview-engine/src/package/index.js";
import { deviceProfiles } from "../../preview-engine/src/render/profiles.js";
import type { Issue, PackageFiles, WidgetFamilyName, WidgetManifest, WidgetSize } from "../../preview-engine/src/types.js";
import type { TutorialProgress } from "./tutorialProgress.ts";

export interface Project {
  id: string;
  name: string;
  files: PackageFiles;
  /// Preview-only API mocks (JSON text); never exported.
  fixtures: string;
  tutorial?: TutorialProgress;
  tutorialCloudExample?: true;
  createdAt: number;
  updatedAt: number;
}

/// A bundled template or Gallery widget, as served in templates.json.
export interface Template {
  id: string;
  source: "template" | "gallery" | string;
  name: string;
  description: string;
  category: string;
  /// Curated: Gallery widgets and templates whose meta.json sets featured.
  featured?: boolean;
  tags?: string[];
  icon?: string | null;
  files: Record<string, string | { base64: string }>;
}

export interface PackageReport {
  manifest: WidgetManifest | null;
  issues: Issue[];
  valid: boolean;
}

/// WidgetKit family -> `$getenv("widget-size")` value (ScriptWidgetDataObject).
export const familyEnvironment: Record<WidgetFamilyName, WidgetSize> = {
  systemSmall: "small", systemMedium: "medium", systemLarge: "large", systemExtraLarge: "extraLarge",
  systemExtraLargePortrait: "extraLargePortrait", accessoryCircular: "accessoryCircular",
  accessoryRectangular: "accessoryRectangular", accessoryInline: "accessoryInline",
};

export const familyLabels: Record<WidgetSize, string> = {
  small: "Small", medium: "Medium", large: "Large", extraLarge: "Extra Large", extraLargePortrait: "Extra Large Portrait",
  accessoryCircular: "Lock Screen Circular", accessoryRectangular: "Lock Screen Rectangular", accessoryInline: "Lock Screen Inline",
};

/// Families the manifest declares that the selected device can show.
export function previewFamilies(manifest: Pick<WidgetManifest, "supportedFamilies"> | null | undefined, profile: string): WidgetSize[] {
  const declared = (manifest?.supportedFamilies ?? ["systemSmall", "systemMedium", "systemLarge"]).map((family) => familyEnvironment[family]).filter(Boolean);
  const available = declared.filter((family) => deviceProfiles[profile]?.[family]);
  return available.length ? available : (["small", "medium", "large"] as const).filter((family) => deviceProfiles[profile]?.[family]);
}

const base64ToBytes = (value: string): Uint8Array => {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
};

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let index = 0; index < bytes.length; index += 0x8000) binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  return btoa(binary);
}

const projectID = (): string => (globalThis.crypto?.randomUUID ? globalThis.crypto.randomUUID() : `p-${Date.now()}-${Math.random().toString(16).slice(2)}`);

export function createProject(name = "My Widget", files: PackageFiles = newProjectFiles(name)): Project {
  return { id: projectID(), name, files, fixtures: defaultFixtures, createdAt: Date.now(), updatedAt: Date.now() };
}

/// A bundled template or Gallery widget as a Package 2.0 project.
export function projectFromTemplate(template: Template): Project {
  const files: PackageFiles = {};
  for (const [path, value] of Object.entries(template.files)) files[path] = typeof value === "string" ? value : base64ToBytes(value.base64);
  if (typeof files["widget.json"] !== "string") {
    let metadata: Record<string, unknown> = {};
    const meta = files["meta.json"];
    try { metadata = typeof meta === "string" ? JSON.parse(meta) : {}; } catch { metadata = {}; }
    const manifest = legacyManifest(template.name, metadata);
    manifest.id = `local.${projectID().toLowerCase()}`;
    // iPhone runs legacy scripts at every size; declare the sizes the script
    // handles so the copy previews and exports them.
    const source = typeof files["main.jsx"] === "string" ? files["main.jsx"] : "";
    const handled = (Object.entries(familyEnvironment) as Array<[WidgetFamilyName, WidgetSize]>)
      .filter(([family, size]) => family.startsWith("system") ? manifest.supportedFamilies.includes(family) || source.includes(`"${size}"`) : source.includes(`"${size}"`))
      .map(([family]) => family);
    manifest.supportedFamilies = [...new Set([...manifest.supportedFamilies, ...handled])];
    // widget.json now carries meta.json's description, category, and tags.
    delete files["meta.json"];
    files["widget.json"] = `${JSON.stringify(manifest, null, 2)}\n`;
  }
  return createProject(template.name, files);
}

export function manifestOf(project: Pick<Project, "files">): { manifest: WidgetManifest; error?: undefined } | { manifest?: undefined; error: string } {
  const text = project.files["widget.json"];
  if (typeof text !== "string") return { error: "widget.json is missing." };
  return decodeManifest(text);
}

export function packageReport(project: Pick<Project, "files">): PackageReport {
  const decoded = manifestOf(project);
  if (decoded.error !== undefined) return { manifest: null, issues: [{ severity: "error", code: "manifest", message: decoded.error }], valid: false };
  const report = validateManifest(decoded.manifest, Object.keys(project.files));
  return { manifest: decoded.manifest, ...report };
}

/// Runtime needs binary file presence, without receiving the image bytes.
export const executionFiles = (files: PackageFiles): PackageFiles =>
  Object.fromEntries(Object.entries(files).map(([name, value]) => [name, typeof value === "string" ? value : new Uint8Array()]));

export const textFiles = (files: PackageFiles): Record<string, string> =>
  Object.fromEntries(Object.entries(files).filter((entry): entry is [string, string] => typeof entry[1] === "string"));

const imageTypes: Record<string, string> = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", webp: "image/webp", gif: "image/gif", heic: "image/heic" };

/// Package images as data URLs for the renderer.
export function resourceURLs(files: PackageFiles): Record<string, string> {
  const result: Record<string, string> = {};
  for (const [path, value] of Object.entries(files)) {
    const type = imageTypes[path.split(".").pop()?.toLowerCase() ?? ""];
    if (type && value instanceof Uint8Array) result[path] = `data:${type};base64,${bytesToBase64(value)}`;
  }
  return result;
}

/// Package-relative file names a user may create in the Studio.
export function validNewPath(path: string, existing: PackageFiles): string | null {
  if (!/^[A-Za-z0-9][A-Za-z0-9._ -]*(\/[A-Za-z0-9][A-Za-z0-9._ -]*)*$/.test(path)) return "Use letters, numbers, dots, dashes, spaces, and / for folders.";
  if (path.split("/").length > 16) return "Folders can be at most 16 levels deep.";
  if (!/\.(jsx?|json|txt|md|csv)$/i.test(path) && !path.startsWith("image/")) return "Text files must end in .js, .jsx, .json, .txt, .md, or .csv.";
  if (Object.keys(existing).some((name) => name.toLowerCase() === path.toLowerCase())) return "A file with this name already exists.";
  return null;
}

/// The file to open first: the manifest's entry when present.
export function initialPath(project: Project): string {
  const report = packageReport(project);
  if (report.manifest && typeof project.files[report.manifest.entry] === "string") return report.manifest.entry;
  return Object.keys(project.files).find((path) => typeof project.files[path] === "string") ?? "widget.json";
}

/// widget.json first, then files in name order.
export function sortedPaths(files: PackageFiles): string[] {
  return Object.keys(files).sort((a, b) => (a === "widget.json" ? -1 : b === "widget.json" ? 1 : a.localeCompare(b)));
}
