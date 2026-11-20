import type { Appearance, Issue, RenderingMode, WidgetSize } from "../types.js";

export interface RenderedWidget {
  element: HTMLElement;
  size: { width: number; height: number };
  diagnostics: Issue[];
}

export function renderWidget(treeJSON: string, options?: {
  family?: WidgetSize;
  profile?: string;
  appearance?: Appearance;
  renderingMode?: RenderingMode;
  lockScreen?: boolean;
  resources?: Record<string, string>;
  document?: Document;
  /// A fixed clock for absolute <date> styles and clock animation poses, in milliseconds since 1970.
  now?: number | null;
  /// "live" animates with CSS; "firstFrame" draws what ImageRenderer captures.
  animations?: "live" | "firstFrame";
  /// Display-only fixed elapsed seconds for deterministic swing poses.
  animationElapsed?: number | null;
  reduceTransparency?: boolean;
  reduceMotion?: boolean;
  /// The QuickJS hosts only (Android, Windows, Linux): <list> becomes a list the host scrolls or cuts off,
  /// and `colors` supplies the "material.<role>" color names: it maps each role to
  /// [red, green, blue, alpha] (0-255, alpha 0-1) for both appearances (Android's wallpaper colors).
  /// Without this option the renderer draws what iPhone, iPad and Mac draw: the rows of a <list> that fit.
  /// A role that `colors` does not supply, on any system, is a fixed color: the baseline Material 3 scheme.
  android?: { colors?: { light?: Record<string, number[]>; dark?: Record<string, number[]> } | null } | null;
}): Promise<RenderedWidget>;

export function lineHeight(size: number): number;
