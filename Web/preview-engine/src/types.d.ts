// Shared types for the preview engine's public JavaScript modules. The engine
// stays plain JavaScript (it runs directly in Node and is concatenated into
// the sandbox); these declarations type it for TypeScript consumers such as
// Web Studio.

export type WidgetFamilyName = "systemSmall" | "systemMedium" | "systemLarge" | "systemExtraLarge" | "systemExtraLargePortrait" | "accessoryCircular" | "accessoryRectangular" | "accessoryInline";
export type WidgetSize = "small" | "medium" | "large" | "extraLarge" | "extraLargePortrait" | "accessoryCircular" | "accessoryRectangular" | "accessoryInline";
export type Permission = "network" | "location" | "health" | "calendar" | "reminders" | "remindersWrite" | "photos" | "services" | "music" | "storage" | "icloud" | "files";
export type Severity = "error" | "warning" | "info";
export type Appearance = "light" | "dark";
export type RenderingMode = "fullColor" | "accented" | "vibrant";

/// Package 2.0 widget.json (WidgetPackageManifest).
export interface WidgetManifest {
  formatVersion: number;
  id: string;
  name: string;
  version: string;
  runtimeVersion: string;
  minimumRuntimeVersion?: string | null;
  timeline?: import("./timeline.js").TimelineSchedule | null;
  entry: string;
  supportedFamilies: WidgetFamilyName[];
  permissions: Permission[];
  networkDomains: string[];
  description?: string | null;
  category?: string | null;
  icon?: string | null;
  preview?: string | null;
  license?: string | null;
  plugins?: string[] | null;
  tags?: string[] | null;
  author?: { name: string; url?: string | null } | null;
  actions?: Array<{ id: string; title: string; systemImage: string; function: string; description?: string | null }> | null;
  controls?: Array<Record<string, unknown>> | null;
  pushUpdates?: { registrationURL: string; channel: string } | null;
}

export interface Issue {
  severity: Severity;
  code: string;
  message: string;
}

export interface ValidationReport {
  issues: Issue[];
  valid: boolean;
}

/// Package files: text as strings, binary resources as bytes.
export type PackageFiles = Record<string, string | Uint8Array>;

export interface LogEntry {
  level: "log" | "error";
  message: string;
}

export interface ExecutionResult {
  /// Canonical tree JSON, or null when the script failed.
  tree: string | null;
  error: { kind: string; message: string } | null;
  logs: LogEntry[];
  diagnostics: Issue[];
  mockState?: { storage: Record<string, unknown>; remindersState: { formatVersion: number; items: Array<Record<string, unknown>>; receipts: Array<Record<string, unknown>> } };
  timing?: { compileMilliseconds: number; executeMilliseconds: number };
}
