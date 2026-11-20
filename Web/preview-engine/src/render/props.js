// Ports of the native property readers and attribute parsers. Each function
// names its Swift source; keep the quirks (string-only readers, ARGB hex,
// omitted empty split parts) because they define what widgets look like.

/// Swift `String.split(separator:)`: empty subsequences are omitted.
export const swiftSplit = (value, separator) => value.split(separator).filter((part) => part !== "");

/// Swift `Double(String)`: strict, no surrounding whitespace.
export function swiftDouble(text) {
  if (typeof text !== "string") return null;
  if (/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(text)) return Number(text);
  if (/^[+-]?(inf|infinity)$/i.test(text)) return text.startsWith("-") ? -Infinity : Infinity;
  if (/^[+-]?nan$/i.test(text)) return NaN;
  if (/^[+-]?0[xX][0-9a-fA-F]+$/.test(text)) return (text.startsWith("-") ? -1 : 1) * parseInt(text.replace(/^[+-]?0[xX]/, ""), 16);
  return null;
}

export function parseRotation3D(value) {
  if (typeof value !== "string") return null;
  const parts = value.split(",");
  if (parts.length !== 4) return null;
  const values = parts.map(part => swiftDouble(part.trim()));
  if (!values.every(value => typeof value === "number" && Number.isFinite(value))) return null;
  const scale = Math.max(...values.slice(1).map(value => Math.abs(value)));
  if (scale === 0) return null;
  return {degree:values[0] % 360,x:values[1]/scale,y:values[2]/scale,z:values[3]/scale};
}

/// Swift `Int(String)`.
export const swiftInt = (text) => (typeof text === "string" && /^[+-]?\d+$/.test(text) ? Number(text) : null);

/// ScriptWidgetRuntimeElement.getProp*.
export function propReader(props) {
  const map = props ?? {};
  const has = (key) => Object.prototype.hasOwnProperty.call(map, key);
  return {
    has,
    keys: () => Object.keys(map),
    raw: (key) => (has(key) ? map[key] : undefined),
    string(key, or) {
      if (has(key) && typeof map[key] === "string") return map[key];
      if (or !== undefined && has(or) && typeof map[or] === "string") return map[or];
      return null;
    },
    bool(key) {
      const value = map[key];
      if (typeof value === "boolean") return value;
      if (typeof value === "number") return value === 1 ? true : value === 0 ? false : null;
      if (value === "true" || value === "yes") return true;
      if (value === "false" || value === "no") return false;
      return null;
    },
    int(key) {
      const value = map[key];
      if (typeof value === "number") return Number.isInteger(value) ? value : null;
      if (typeof value === "boolean") return value ? 1 : 0;
      return swiftInt(value);
    },
    double(key) {
      const value = map[key];
      if (typeof value === "number") return value;
      if (typeof value === "boolean") return value ? 1 : 0;
      return swiftDouble(value);
    },
  };
}

// MARK: - Colors (ScriptWidgetElementColor.swift)

// UIKit system colors resolved by SwiftUI's named colors, light and dark.
const systemColors = {
  light: {
    black: [0, 0, 0, 1], white: [255, 255, 255, 1], clear: [0, 0, 0, 0],
    gray: [142, 142, 147, 1], red: [255, 56, 60, 1], green: [52, 199, 89, 1], blue: [0, 136, 255, 1],
    orange: [255, 141, 40, 1], yellow: [255, 204, 0, 1], pink: [255, 45, 85, 1], purple: [203, 48, 224, 1],
    primary: [0, 0, 0, 1], secondary: [60, 60, 67, 0.6],
  },
  dark: {
    black: [0, 0, 0, 1], white: [255, 255, 255, 1], clear: [0, 0, 0, 0],
    gray: [142, 142, 147, 1], red: [255, 66, 69, 1], green: [48, 209, 88, 1], blue: [0, 145, 255, 1],
    orange: [255, 146, 48, 1], yellow: [255, 214, 0, 1], pink: [255, 55, 95, 1], purple: [219, 52, 242, 1],
    primary: [255, 255, 255, 1], secondary: [235, 235, 245, 0.6],
  },
};

// macOS 26 differs from iOS in label alphas and the dark gray, measured by
// sampling SwiftUI colors with ImageRenderer (Tools/ScriptWidgetPreview).
const macSystemColors = {
  light: { ...systemColors.light, primary: [0, 0, 0, 0.847], secondary: [0, 0, 0, 0.498] },
  dark: { ...systemColors.dark, gray: [152, 152, 157, 1], primary: [255, 255, 255, 0.847], secondary: [255, 255, 255, 0.549] },
};

const systemBackgrounds = {
  ios: { light: [255, 255, 255, 1], dark: [0, 0, 0, 1] },
  // ShapeStyle.background, which the macOS widget's containerBackground uses.
  macos: { light: [255, 255, 255, 1], dark: [46, 46, 46, 1] },
};

/// The platform whose SwiftUI metrics the renderer follows ("ios" or
/// "macos"). renderWidget sets it for the synchronous layout pass.
let currentPlatform = "ios";
export const platform = () => currentPlatform;
export function setPlatform(name) {
  const previous = currentPlatform;
  currentPlatform = name === "macos" ? "macos" : "ios";
  return previous;
}

const palette = () => (currentPlatform === "macos" ? macSystemColors : systemColors);

/// The "material.<role>" color names. Android takes them from the wallpaper and
/// hands them over as { light: { primary: [r, g, b, a], ... }, dark: { ... } }.
/// Every other system has no such colors and draws the fixed table below: the
/// browser preview of iPhone, iPad and Mac, and Windows and Linux, which supply
/// no palette. A role that a supplied palette leaves out (Android before 14
/// defines none of them) comes from the table too. `null` means that no render
/// is running; the names are unknown then.
let hostColors = null;
export function setHostColors(colors) {
  const previous = hostColors;
  hostColors = colors === null ? null : (colors && typeof colors === "object" ? colors : {});
  return previous;
}
const hostColorPrefix = "material.";

/// The fixed colors of the 25 roles: the baseline Material 3 scheme. Compared
/// value by value with androidx.compose.material3.tokens (ColorLightTokens,
/// ColorDarkTokens and PaletteTokens, "VERSION: v0_210") at
/// https://github.com/androidx/androidx/tree/e4f55394b8035b5eb550f17ec130243c7cb9f64d/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/tokens
/// The roles and their order are those of Android's ThemeColors. The Swift
/// runtime has the same table (ScriptWidgetMaterialPalette); its test
/// testBrowserPreviewHasTheSamePalette reads the two lines below, so keep their form.
const materialTable = (text) => {
  const words = text.split(" ");
  const table = {};
  for (let index = 0; index < words.length; index += 2) {
    const hex = parseInt(words[index + 1], 16);
    table[words[index]] = Object.freeze([hex >> 16, (hex >> 8) & 0xff, hex & 0xff, 1]);
  }
  return Object.freeze(table);
};
export const fixedMaterialColors = Object.freeze({
  light: materialTable("primary 6750A4 onPrimary FFFFFF primaryContainer EADDFF onPrimaryContainer 21005D secondary 625B71 onSecondary FFFFFF secondaryContainer E8DEF8 onSecondaryContainer 1D192B tertiary 7D5260 onTertiary FFFFFF tertiaryContainer FFD8E4 onTertiaryContainer 31111D background FEF7FF onBackground 1D1B20 surface FEF7FF onSurface 1D1B20 surfaceVariant E7E0EC onSurfaceVariant 49454F surfaceContainerLowest FFFFFF surfaceContainerLow F7F2FA surfaceContainer F3EDF7 surfaceContainerHigh ECE6F0 surfaceContainerHighest E6E0E9 outline 79747E outlineVariant CAC4D0"),
  dark: materialTable("primary D0BCFF onPrimary 381E72 primaryContainer 4F378B onPrimaryContainer EADDFF secondary CCC2DC onSecondary 332D41 secondaryContainer 4A4458 onSecondaryContainer E8DEF8 tertiary EFB8C8 onTertiary 492532 tertiaryContainer 633B48 onTertiaryContainer FFD8E4 background 141218 onBackground E6E0E9 surface 141218 onSurface E6E0E9 surfaceVariant 49454F onSurfaceVariant CAC4D0 surfaceContainerLowest 0F0D13 surfaceContainerLow 1D1B20 surfaceContainer 211F26 surfaceContainerHigh 2B2930 surfaceContainerHighest 36343B outline 938F99 outlineVariant 49454F"),
});
export const systemBackground = (appearance) => systemBackgrounds[currentPlatform][appearance];

/// Color(hex:): trims non-alphanumerics, scans leading hex digits, and treats
/// 8 digits as ARGB. Any other length becomes (1,1,1,1)/255.
export function hexColor(value) {
  const hex = value.replace(/^[^A-Za-z0-9]+|[^A-Za-z0-9]+$/g, "");
  const digits = /^[0-9a-fA-F]*/.exec(hex)[0];
  const scanned = digits === "" ? 0n : BigInt("0x" + digits.slice(0, 16));
  const int = scanned & 0xffffffffffffffffn;
  let a; let r; let g; let b;
  if (hex.length === 6) { a = 255n; r = int >> 16n; g = (int >> 8n) & 0xffn; b = int & 0xffn; }
  else if (hex.length === 8) { a = int >> 24n; r = (int >> 16n) & 0xffn; g = (int >> 8n) & 0xffn; b = int & 0xffn; }
  else { a = 1n; r = 1n; g = 1n; b = 1n; }
  const channel = (x) => Number(x & 0xffffffffn);
  return [channel(r), channel(g), channel(b), Math.min(1, channel(a) / 255)];
}

function builtinColor(name, appearance) {
  if (name.startsWith(hostColorPrefix)) {
    if (hostColors === null) return null;
    const role = name.slice(hostColorPrefix.length);
    const value = hostColors[appearance]?.[role];
    if (Array.isArray(value) && value.length === 4 && value.every((item) => typeof item === "number" && Number.isFinite(item))) return value;
    const fixed = fixedMaterialColors[appearance];
    return fixed && Object.hasOwn(fixed, role) ? fixed[role] : null;
  }
  return Object.prototype.hasOwnProperty.call(systemColors.light, name) ? palette()[appearance][name] : null;
}

/// getColorFromColorValue: "#hex", "name", "#hex,opacity", "name,opacity".
export function parseColor(value, appearance = "light") {
  const parts = swiftSplit(value, ",");
  const base = (part) => (part.startsWith("#") ? hexColor(part) : builtinColor(part, appearance));
  if (parts.length === 1) return base(value.startsWith("#") ? value : value);
  if (parts.length === 2) {
    const color = base(parts[0]);
    if (!color) return null;
    const opacity = swiftDouble(parts[1]);
    return opacity === null ? color : [color[0], color[1], color[2], color[3] * Math.max(0, Math.min(1, opacity))];
  }
  return null;
}

export const cssColor = ([r, g, b, a]) => `rgba(${Math.round(r)}, ${Math.round(g)}, ${Math.round(b)}, ${+a.toFixed(4)})`;

/// ScriptWidgetElementPoint.getPointFromPointValue.
export function parsePoint(value) {
  const named = {
    zero: [0, 0], center: [0.5, 0.5], leading: [0, 0.5], trailing: [1, 0.5], top: [0.5, 0], bottom: [0.5, 1],
    topLeading: [0, 0], topTrailing: [1, 0], bottomLeading: [0, 1], bottomTrailing: [1, 1],
  };
  const parts = swiftSplit(value, ",");
  if (parts.length === 1) return named[value] ?? [0, 0];
  if (parts.length === 2) return [swiftDouble(parts[0]) ?? 0, swiftDouble(parts[1]) ?? 0];
  return [0, 0];
}

/// ScriptWidgetElementGradient.getGradient (SwiftyJSON `stringValue` and
/// `doubleValue` coerce numbers and strings and default to "" / 0).
export function parseGradient(value, appearance = "light") {
  const fallback = { type: "linear", colors: [palette()[appearance].orange, palette()[appearance].red], start: [0, 0.5], end: [1, 0.5] };
  let json;
  try { json = JSON.parse(value.slice("gradient:".length)); } catch { return fallback; }
  if (!json || typeof json !== "object") return fallback;
  const stringValue = (item) => (typeof item === "string" ? item : typeof item === "number" || typeof item === "boolean" ? String(item) : "");
  const doubleValue = (item) => (typeof item === "number" ? item : typeof item === "string" ? (Number.isFinite(Number(item)) && item.trim() !== "" ? Number(item) : 0) : item === true ? 1 : 0);
  const colors = (Array.isArray(json.colors) ? json.colors : []).map((item) => parseColor(stringValue(item), appearance) ?? [0, 0, 0, 0]);
  const type = stringValue(json.type);
  if (type === "linear") return { type, colors, start: parsePoint(stringValue(json.startPoint)), end: parsePoint(stringValue(json.endPoint)) };
  if (type === "radial") return { type, colors, center: parsePoint(stringValue(json.center)), startRadius: doubleValue(json.startRadius), endRadius: doubleValue(json.endRadius) };
  if (type === "angular") return { type, colors, center: parsePoint(stringValue(json.center)) };
  return fallback;
}

/// ScriptWidgetAttributeColor: a solid color, a gradient, or nothing.
export function parsePaint(value, appearance) {
  if (typeof value !== "string") return null;
  if (value.startsWith("gradient:")) return { gradient: parseGradient(value, appearance) };
  const color = parseColor(value, appearance);
  return color ? { color } : null;
}

/// CSS for a gradient laid out in a box of `width` x `height` points.
export function gradientCSS(gradient, width, height) {
  const stops = (positions) => gradient.colors.map((color, index) => `${cssColor(color)} ${positions(index)}`).join(", ");
  const n = Math.max(1, gradient.colors.length - 1);
  if (gradient.colors.length === 0) return "transparent";
  if (gradient.colors.length === 1) return cssColor(gradient.colors[0]);
  if (gradient.type === "radial") {
    const [cx, cy] = gradient.center;
    return `radial-gradient(circle farthest-corner at ${cx * width}px ${cy * height}px, ${stops((i) => `${gradient.startRadius + (i / n) * (gradient.endRadius - gradient.startRadius)}px`)})`;
  }
  if (gradient.type === "angular") {
    const [cx, cy] = gradient.center;
    return `conic-gradient(from 90deg at ${cx * width}px ${cy * height}px, ${stops((i) => `${(i / n) * 360}deg`)})`;
  }
  const sx = gradient.start[0] * width; const sy = gradient.start[1] * height;
  const ex = gradient.end[0] * width; const ey = gradient.end[1] * height;
  const dx = ex - sx; const dy = ey - sy;
  if (dx === 0 && dy === 0) return cssColor(gradient.colors.at(-1));
  const angle = Math.atan2(dx, -dy);
  const ux = Math.sin(angle); const uy = -Math.cos(angle);
  const length = Math.abs(width * Math.sin(angle)) + Math.abs(height * Math.cos(angle));
  const along = (x, y) => ((x - width / 2) * ux + (y - height / 2) * uy + length / 2);
  const t0 = along(sx, sy); const t1 = along(ex, ey);
  return `linear-gradient(${(angle * 180) / Math.PI}deg, ${stops((i) => `${t0 + (i / n) * (t1 - t0)}px`)})`;
}

// MARK: - Layout attributes

export const alignments = {
  center: ["center", "center"], leading: ["start", "center"], trailing: ["end", "center"],
  top: ["center", "start"], bottom: ["center", "end"], topLeading: ["start", "start"],
  topTrailing: ["end", "start"], bottomLeading: ["start", "end"], bottomTrailing: ["end", "end"],
};

/// ScriptWidgetAttributeFrameModifier.
export function parseFrame(reader) {
  const raw = reader.raw("frame");
  let value = reader.string("frame");
  if (value === null && typeof raw === "number") value = Number.isInteger(raw) ? `${raw}.0` : String(raw);
  const result = { mode: "none", alignment: "center", width: 0, height: 0 };
  if (value === null) return result;
  const parts = swiftSplit(value, ",");
  const alignmentName = (name) => (alignments[name] ? name : "center");
  if (parts.length === 1) {
    if (value === "max") result.mode = "max";
    else {
      const side = swiftDouble(value);
      if (side !== null && Number.isFinite(side) && side >= 0) Object.assign(result, { mode: "size", width: side, height: side });
    }
  } else if (parts.length === 2) {
    const [a, b] = parts;
    const w = swiftDouble(a); const h = swiftDouble(b);
    if (w !== null && h !== null) Object.assign(result, { mode: "size", width: w, height: h });
    else {
      if (a === "max") {
        if (h !== null) Object.assign(result, { mode: "height", height: h });
        else Object.assign(result, { mode: "max", alignment: alignmentName(b) });
      }
      if (b === "max" && w !== null) Object.assign(result, { mode: "width", width: w });
    }
  } else if (parts.length === 3) {
    const [a, b, c] = parts;
    const w = swiftDouble(a); const h = swiftDouble(b);
    if (w !== null && h !== null) Object.assign(result, { mode: "size", width: w, height: h, alignment: alignmentName(c) });
    if (a === "max" && h !== null) Object.assign(result, { mode: "height", height: h, alignment: alignmentName(c) });
    if (b === "max" && w !== null) Object.assign(result, { mode: "width", width: w, alignment: alignmentName(c) });
  }
  return result;
}

/// ScriptWidgetAttributePaddingModifier: string values only.
export function parsePadding(reader) {
  const value = reader.string("padding");
  if (value === null) return null;
  const parts = swiftSplit(value, ",");
  const number = (text) => swiftDouble(text) ?? 0;
  if (parts.length === 1) { const all = number(value); return [all, all, all, all]; }
  if (parts.length === 2) {
    const amount = number(parts[1]);
    const edges = { top: [1, 0, 0, 0], leading: [0, 0, 0, 1], bottom: [0, 0, 1, 0], trailing: [0, 1, 0, 0],
      horizontal: [0, 1, 0, 1], vertical: [1, 0, 1, 0], all: [1, 1, 1, 1] }[parts[0]] ?? [1, 1, 1, 1];
    return edges.map((on) => on * amount);
  }
  if (parts.length === 4) return parts.map(number);
  return null;
}

// MARK: - Fonts (ScriptWidgetAttributeFontModifier.swift)

// iOS Dynamic Type "Large" text styles: size, line height, weight.
export const textStyles = {
  largeTitle: [34, 41, 400], title: [28, 34, 400], title2: [22, 28, 400], title3: [20, 25, 400],
  headline: [17, 22, 600], body: [17, 22, 400], callout: [16, 21, 400], subheadline: [15, 20, 400],
  footnote: [13, 18, 400], caption: [12, 16, 400], caption2: [11, 13, 400],
};
// macOS 26 text styles: size, first-line height, line advance, weight, and
// the gap SwiftUI leaves below the line in a VStack (the font's leading on
// the 2x grid). Measured with NSHostingController at display scale 2.
const macTextStyles = {
  largeTitle: [26, 31, 32, 400, 1.5], title: [22, 26, 26, 400, 0.5], title2: [17, 20.5, 22, 400, 2], title3: [15, 19, 20, 400, 2.5],
  headline: [13, 16, 16, 700, 1], body: [13, 16, 16, 400, 1], callout: [12, 15, 15, 400, 1], subheadline: [11, 14, 14, 400, 1.5],
  footnote: [10, 13, 13, 400, 1.5], caption: [10, 13, 13, 400, 1.5], caption2: [10, 13, 13, 400, 1.5],
};

/// A named text style as a font for the current platform.
export function styleFont(name) {
  if (currentPlatform === "macos") {
    const [size, natural, lineHeight, weight, gap] = macTextStyles[name];
    return { size, natural, lineHeight, weight, gap, design: "default", textStyle: name };
  }
  const [size, lineHeight, weight] = textStyles[name];
  return { size, lineHeight, weight, design: "default", textStyle: name };
}

const weights = { ultraLight: 100, thin: 200, light: 300, regular: 400, medium: 500, semibold: 600, bold: 700, heavy: 800, black: 900 };
const designs = { monospaced: "monospaced", rounded: "rounded", serif: "serif", default: "default" };

/// Returns {size, lineHeight, weight, design, family?} or null (no font set).
export function parseFont(value) {
  if (typeof value !== "string") return null;
  const fromName = (name, designName) => {
    if (textStyles[name]) return styleFont(name);
    const size = swiftDouble(name);
    if (size === null) return null;
    return { size, lineHeight: null, weight: 400, design: (designName && designs[designName]) || "default" };
  };
  const parts = swiftSplit(value, ",");
  let font = null;
  let weight = null;
  if (parts.length === 1) font = fromName(value, null);
  else if (parts.length === 2) { font = fromName(parts[0], null); weight = weights[parts[1]] ?? null; }
  else if (parts.length === 3) {
    if (parts[0] === "custom") font = { size: swiftDouble(parts[2]) ?? 10, lineHeight: null, weight: 400, design: "default", family: parts[1] };
    else { font = fromName(parts[0], parts[2]); weight = weights[parts[1]] ?? null; }
  }
  if (font && weight !== null) font.weight = weight;
  return font;
}

/// Text without a font uses .body.
export const defaultFont = () => styleFont("body");

/// ScriptWidgetAttributeFontModifier: `font`, refined by `fontWeight` (or
/// the older `weight`) and `fontDesign`.
export function elementFont(reader, fallback = defaultFont()) {
  const font = { ...(parseFont(reader.string("font")) ?? fallback) };
  const weight = weights[reader.string("fontWeight") ?? reader.string("weight") ?? ""];
  if (weight !== undefined) font.weight = weight;
  const design = designs[reader.string("fontDesign") ?? ""];
  if (design !== undefined && !font.family) font.design = design;
  return font;
}

/// Off Apple platforms SF Pro is unavailable; pages that load the bundled
/// "ScriptWidget Inter" face (OFL) get consistent metrics on every OS.
/// Test hooks for measuring that: globalThis.__scriptWidgetFontStack =
/// "fallback" (generic fonts) or "inter" (Inter only).
const fallbackOnly = () => globalThis.__scriptWidgetFontStack === "fallback";
const interOnly = () => globalThis.__scriptWidgetFontStack === "inter";

export function fontFamily(font) {
  if (interOnly() && font.design !== "monospaced" && font.design !== "serif") return "\"ScriptWidget Inter\", Arial, sans-serif";
  if (fallbackOnly()) return font.design === "monospaced" ? "Consolas, \"Courier New\", monospace" : "\"Segoe UI\", Roboto, Arial, Helvetica, sans-serif";
  if (font.family) return `"${font.family.replace(/"/g, "")}", -apple-system, "ScriptWidget Inter", system-ui, sans-serif`;
  switch (font.design) {
    case "rounded": return `"SF Pro Rounded", ui-rounded, -apple-system, "ScriptWidget Inter", system-ui, sans-serif`;
    case "monospaced": return `ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace`;
    case "serif": return `"New York", ui-serif, Georgia, "Times New Roman", serif`;
    default: return `-apple-system, BlinkMacSystemFont, "SF Pro Text", "ScriptWidget Inter", system-ui, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif`;
  }
}
