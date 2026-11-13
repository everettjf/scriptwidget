// Web renderer for resolved ScriptWidget element trees. Builders mirror the
// native ScriptWidgetElementTag* classes and ScriptWidgetAttributeGeneral's
// modifier order; layout.js reproduces SwiftUI sizing; drawing uses
// absolutely positioned elements. User text is inserted with textContent.

import {
  alignments, cssColor, defaultFont, elementFont, fontFamily, gradientCSS, parseColor, parseFont, parseFrame,
  parsePadding, parsePaint, parseRotation3D, platform, propReader, setPlatform, styleFont, swiftDouble, systemBackground,
} from "./props.js";
import { prepareGif } from "./gif.js";
import { clockPeriods, clockPeriod, clockPhase, swingDuration, swingDistance, swingPhase } from "./animation.js";
import { coverage, generalProps, ignoredProp } from "./coverage.js";
import { deviceProfiles, widgetSize } from "./profiles.js";
import { symbolMetrics } from "./symbolMetrics.generated.js";
import { symbolShapes } from "./symbolShapes.js";
import { lucideIcons, sfSymbolToLucide } from "./icons.generated.js";

/// A path is closed when it uses Z or its final absolute point returns to
/// the starting move (Lucide draws some outlines that way).
// Unique mask ids across every widget drawn in a page.
let maskCounter = 0;

function closedPath(d) {
  if (/z/i.test(d)) return true;
  const start = /^\s*M\s*(-?[\d.]+)[\s,]*(-?[\d.]+)/.exec(d);
  const lastCommand = /([A-Za-z])[^A-Za-z]*$/.exec(d);
  if (!start || !lastCommand || lastCommand[1] !== lastCommand[1].toUpperCase()) return false;
  const numbers = d.match(/-?\d*\.?\d+/g) ?? [];
  return numbers.length >= 2 && Number(numbers.at(-2)) === Number(start[1]) && Number(numbers.at(-1)) === Number(start[2]);
}

/// Closest open icon for an SF Symbol name: exact, then without style
/// suffixes (.fill, .circle, .square, ...), then shorter prefixes.
export function lucideIconFor(systemName) {
  const variants = new Set();
  let name = systemName;
  variants.add(name);
  const stripped = name.replace(/\.(fill|circle|square|rectangle|slash|badge|inverse)(?=\.|$)/g, "");
  variants.add(stripped);
  const parts = stripped.split(".");
  for (let length = parts.length - 1; length > 0; length -= 1) variants.add(parts.slice(0, length).join("."));
  for (const variant of variants) if (sfSymbolToLucide[variant]) return lucideIcons[sfSymbolToLucide[variant]];
  return null;
}
import {
  AspectNode, DecorationNode, FixedNode, FlexibleNode, FrameNode, GridNode, Node, PaddingNode, SpacerNode, StackNode, TextNode,
  ZStackNode, createTextMeasurer, fillText,
} from "./layout.js";

/// Overlay: the first child fills the frame; the second is aligned to the
/// bottom (MineGaugeView's `.overlay(label(), alignment: .bottom)`).
class BottomOverlayNode extends Node {
  constructor(base, overlay) { super(); this.base = base; this.overlay = overlay; this.children = [base, overlay]; }
  size(pw, ph) { return this.base.size(pw, ph); }
  place(x, y, width, height) {
    super.place(x, y, width, height);
    this.base.place(0, 0, width, height);
    const [w, h] = this.overlay.size(width, height);
    this.overlay.place((width - w) / 2, height - h, w, h);
  }
}

const naturalLineRatio = 1.1934;

// macOS 26 single-line heights of .system(size:) for sizes 1...160; SwiftUI
// lays macOS text out on whole points. A fractional size uses the next whole
// size, which matches most but not all measured half sizes.
const macLineHeights = [2,3,4,5,7,8,9,10,11,13,14,15,16,17,19,19,20,21,23,24,25,26,27,28,29,30,32,33,34,35,37,38,39,40,41,43,44,45,46,47,49,50,51,52,53,54,55,56,57,59,60,61,62,63,65,66,67,68,69,71,72,73,74,76,77,78,79,80,82,83,84,85,86,88,89,89,90,91,93,94,95,96,98,99,100,101,102,104,105,106,107,108,110,111,112,113,114,116,117,118,119,121,122,123,124,124,126,127,128,129,130,132,133,134,135,136,138,139,140,141,143,144,145,146,147,149,150,151,152,153,155,156,157,158,159,160,161,162,163,165,166,167,168,169,171,172,173,174,175,177,178,179,180,181,183,184,185,186,188,189];

/// Single-line Text height: SF natural line height on the 2x pixel grid
/// (iOS) or the measured whole-point height (macOS).
export function lineHeight(size) {
  if (platform() === "macos") {
    const whole = Math.ceil(size);
    if (whole <= 0) return 0;
    return macLineHeights[whole - 1] ?? Math.ceil(size * naturalLineRatio);
  }
  return Math.ceil(size * naturalLineRatio * 2) / 2;
}

// macOS 26 first-baseline offsets of .system(size:) for sizes 1...160,
// measured from rendered glyphs at 8x (whole points from size 2).
const macBaselines = [0.75,2,3,4,5,6,7,8,9,10,11,12,13,14,15,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69,70,71,72,73,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,96,97,98,99,100,101,102,102,103,104,105,106,107,108,109,110,111,112,113,114,115,116,117,118,119,120,121,122,123,124,125,126,127,128,129,130,131,131,132,133,134,135,136,137,138,139,140,141,142,143,144,145,146,147,148,149,150,151,152,153,154,155];

/// Native first baseline below the top of a Text frame (SF Pro).
function nativeBaseline(size) {
  if (platform() === "macos") return macBaselines[Math.ceil(size) - 1] ?? size * 0.9521;
  return size * 0.9521;
}

/// New York draws lining figures in SwiftUI; browsers default to old-style.
const numericVariant = (style) => (style.design === "serif" && !style.custom ? "lining-nums" : "");

function textStyleFor(font) {
  const natural = font.natural ?? lineHeight(font.size);
  // Lines advance by the text style's line height; sized fonts advance by
  // their natural height (iOS: size x 1.1934, measured at 8x).
  const leading = platform() === "macos" ? Math.max(natural, font.lineHeight ?? natural) : font.lineHeight ?? font.size * naturalLineRatio;
  const family = fontFamily(font);
  return { ...font, natural, leading, family, custom: Boolean(font.family), hyphenate: Boolean(font.textStyle), key: `${family}|${font.size}|${font.weight}|${leading}` };
}

// MARK: - Tree decoding

function decodeTree(treeJSON) {
  const decodeDictionary = (map) => Object.fromEntries(Object.entries(map).map(([key, item]) => [key, decode(item)]));
  function decode(value) {
    if (value === null || typeof value !== "object") return value;
    if (Array.isArray(value)) return value.map(decode);
    if ("$element" in value) {
      return { tag: typeof value.$element === "string" ? value.$element : null, props: value.props ? decodeDictionary(value.props) : null, children: value.children ? value.children.map(decode) : null };
    }
    if ("$dict" in value) return decodeDictionary(value.$dict);
    if ("$date" in value) return { $date: value.$date };
    if ("$number" in value) return value.$number === "-0" ? -0 : Number(value.$number);
    return value;
  }
  return decode(JSON.parse(treeJSON));
}

const isElement = (value) => value !== null && typeof value === "object" && "tag" in value && "children" in value && "props" in value;

function childrenAsElements(element) {
  const result = [];
  const visit = (items) => { for (const item of items) { if (isElement(item)) result.push(item); else if (Array.isArray(item)) visit(item); } };
  visit(element.children ?? []);
  return result;
}

/// String(describing: NSNumber) for text children.
function numberText(value) {
  if (typeof value === "boolean") return value ? "1" : "0";
  if (Number.isInteger(value) && Math.abs(value) >= 1e16) return value.toExponential();
  return String(value);
}

function textFromChildren(element) {
  let text = "";
  for (const child of element.children ?? []) {
    if (typeof child === "string") text += child;
    else if (typeof child === "number" || typeof child === "boolean") text += numberText(child);
    else text += "#ErrorChildType#";
  }
  return text;
}

function collectImageURLs(element, urls, drawableURL) {
  if (!isElement(element)) return;
  const reader = propReader(element.props);
  if (element.tag === "image") { const url = reader.string("url", "src"); const drawable = url ? drawableURL(url) : null; if (drawable) urls.add(drawable); }
  childrenAsElements(element).forEach((child) => collectImageURLs(child, urls, drawableURL));
}

async function naturalSizes(urls, doc) {
  const sizes = new Map();
  await Promise.all([...urls].map(async (url) => {
    const image = doc.createElement("img");
    image.src = url;
    try { await image.decode(); sizes.set(url, [image.naturalWidth, image.naturalHeight]); } catch { /* broken image */ }
  }));
  return sizes;
}

// MARK: - Renderer

/// Renders a canonical tree JSON string into a widget-sized element.
/// Must run in a document with layout (text is measured by the browser).
export async function renderWidget(treeJSON, {
  family = "medium", profile = "iphone-393", appearance = "light", renderingMode = "fullColor", lockScreen = true, resources = {}, document: doc = globalThis.document,
  now = null, animations = "live", animationElapsed = null, reduceTransparency = false, reduceMotion = false,
  // Native hosts (Android) supply these; the web hosts use the defaults.
  size: explicitSize = null, textMeasurer = null, resolveImageURL = null, gifPreparer = null,
} = {}) {
  // Milliseconds since 1970 for a fixed clock (snapshot tests), or null.
  const fixedNow = typeof now === "number" && Number.isFinite(now) ? now : null;
  if (reduceMotion) animations = "firstFrame";
  const size = explicitSize ?? widgetSize(profile, family);
  // Which image URLs can be drawn: inline PNG/JPEG data by default.
  const drawableURL = resolveImageURL ?? ((url) => (/^data:image\/(png|jpeg);base64,/.test(url) ? url : null));
  const diagnostics = [];
  const reported = new Set();
  const report = (severity, code, message) => {
    const key = `${code}:${message}`;
    if (!reported.has(key)) { reported.add(key); diagnostics.push({ severity, code, message }); }
  };
  const color = (value) => parseColor(value, appearance);
  // Button labels default to the accent color, like SwiftUI's button style.
  let tint = null;
  const primary = () => tint ?? color("primary");
  const root = decodeTree(treeJSON);
  const urls = new Set(), gifUses = new Map(), preparedGifs = new Map();
  for (const [path, url] of Object.entries(resources)) if (path.startsWith("image/") && !/\.gif$/i.test(path)) urls.add(url);
  collectImageURLs(root, urls, drawableURL);
  const collectGifs = element => {
    if (!isElement(element)) return;
    const reader = propReader(element.props);
    const found = element.tag === "gif" ? packageGif(reader.string("file") ?? "") : element.tag === "image" ? packageImage(reader.string("name", "id") ?? "") : null;
    const url = typeof found === "string" ? found : found && /\.gif$/i.test(found.path) ? found.url : null;
    if (url) { const use = gifUses.get(url) ?? { image:false }; use.image ||= element.tag === "image"; gifUses.set(url,use); }
    childrenAsElements(element).forEach(collectGifs);
  };
  collectGifs(root);
  // Decode only used GIFs, sequentially. Freeze failures never retain animation.
  for (const [url, use] of gifUses) {
    try {
      const value = await (gifPreparer ?? prepareGif)(url,{document:doc,firstFrame:reduceMotion || animations === "firstFrame" || deviceProfiles[profile]?.platform === "macos",needImage:use.image});
      preparedGifs.set(url,value);
      if (value.firstFrame) urls.add(value.firstFrame);
      if (value.info.frameLimit || value.memoryFallback) report("warning","gif.static_fallback","GIF uses its first frame because the preview animation budget was exceeded");
    } catch { preparedGifs.set(url,null); report("warning","gif.unavailable","GIF could not be decoded within preview input and canvas limits"); }
  }
  const imageSizes = await naturalSizes(urls, doc);
  const measurer = textMeasurer ?? createTextMeasurer(doc);

  // Leaves carry a draw(node, element) callback.
  const leaf = (node, draw) => Object.assign(node, { draw });

  function checkProps(element, reader) {
    const known = coverage.tags[element.tag];
    for (const key of reader.keys()) {
      const reason = ignoredProp(element.tag, key);
      const entry = known?.props?.[key] ?? generalProps[key];
      if (reason) report("info", "prop.ignored", `<${element.tag} ${key}> ${reason}`);
      else if (entry?.state === "unsupported") report("warning", "prop.unsupported", `<${element.tag} ${key}> is not rendered by the web preview yet`);
      else if (entry?.state === "approximated") report("info", "prop.approximated", `<${element.tag} ${key}> is approximated: ${entry.note}`);
    }
  }

  // MARK: Text

  function text(value, font, inputPaint, alignment = "left") {
    const style = textStyleFor(font);
    const paint = inputPaint ?? { color: primary() };
    return leaf(new TextNode(value, style, measurer), (node, element) => {
      Object.assign(element.style, {
        fontFamily: style.family, fontSize: `${style.size}px`, fontWeight: String(style.weight), lineHeight: `${style.leading}px`,
        whiteSpace: "pre-wrap", overflowWrap: "break-word", textAlign: alignment, fontVariantNumeric: numericVariant(style),
      });
      const content = element.ownerDocument.createElement("div");
      // Truncated text draws exactly the lines the layout measured.
      const truncated = node.lines?.text ?? (node.lines && node.lines.lines < node.lines.total ? node.ellipsize(node.text, node.frame.width) : null);
      fillText(content, truncated ?? node.displayText(node.frame.width), measurer.textAdjustments(style));
      // SF text puts its first baseline at the ascent (iOS: 0.9521 x size;
      // macOS: whole points, measured); align the browser's baseline there.
      // Other faces keep CSS half-leading.
      const trim = style.design === "default" && !style.custom
        ? measurer.baseline(style) - nativeBaseline(style.size)
        : (style.leading - style.natural) / 2;
      // A half-point allowance absorbs sub-pixel rounding without fitting an
      // extra glyph that the layout did not measure.
      Object.assign(content.style, { marginTop: `${-trim}px`, width: `${node.frame.width + 0.5}px` });
      // Clipped narrow text stays on one line and is cut at the frame.
      if (node.lines?.clip) { content.style.whiteSpace = "pre"; element.style.overflow = "hidden"; }
      if (alignment !== "left") content.style.width = `${node.frame.width}px`;
      if (truncated !== null) Object.assign(content.style, { whiteSpace: "pre", overflow: "hidden" });
      applyTextPaint(content, paint, node.frame.width, node.frame.height);
      element.appendChild(content);
    });
  }

  function applyTextPaint(element, paint, width, height) {
    if (paint?.gradient) {
      Object.assign(element.style, { color: "transparent", backgroundImage: gradientCSS(paint.gradient, width, height) });
      element.style.webkitBackgroundClip = "text"; element.style.backgroundClip = "text";
    } else element.style.color = cssColor(paint?.color ?? primary());
  }

  const paintOf = (reader, field) => (reader.string(field) !== null ? parsePaint(reader.string(field), appearance) : null);

  // MARK: Shapes

  function shape(kind, paint, { strokeWidth = null, trim = null, cornerRadius = 0 } = {}) {
    return leaf(new FlexibleNode(), (node, element) => {
      const { width, height } = node.frame;
      let x = 0; let y = 0; let w = width; let h = height; let r = 0;
      if (kind === "circle") { const d = Math.min(width, height); x = (width - d) / 2; y = (height - d) / 2; w = d; h = d; }
      if (kind === "capsule") r = Math.min(width, height) / 2;
      if (kind === "rounded") r = Math.min(cornerRadius, width / 2, height / 2);
      const elliptical = kind === "circle" || kind === "ellipse";
      if (strokeWidth === null && !trim) {
        const fill = element.ownerDocument.createElement("div");
        Object.assign(fill.style, { position: "absolute", left: `${x}px`, top: `${y}px`, width: `${w}px`, height: `${h}px`, borderRadius: elliptical ? "50%" : `${r}px` });
        if (paint.gradient) {
          fill.style.backgroundImage = gradientCSS(paint.gradient, width, height);
          fill.style.backgroundPosition = `${-x}px ${-y}px`;
          fill.style.backgroundSize = `${width}px ${height}px`;
        } else fill.style.backgroundColor = cssColor(paint.color);
        element.appendChild(fill);
        return;
      }
      const svgNS = "http://www.w3.org/2000/svg";
      const svg = element.ownerDocument.createElementNS(svgNS, "svg");
      svg.setAttribute("width", String(width)); svg.setAttribute("height", String(height));
      Object.assign(svg.style, { overflow: "visible", position: "absolute", left: "0", top: "0" });
      const outline = element.ownerDocument.createElementNS(svgNS, elliptical ? "ellipse" : "rect");
      const attributes = elliptical ? { cx: x + w / 2, cy: y + h / 2, rx: w / 2, ry: h / 2 } : { x, y, width: w, height: h, rx: r, ry: r };
      for (const [key, value] of Object.entries(attributes)) outline.setAttribute(key, String(value));
      let colorValue = paint.color;
      if (paint.gradient) { report("info", "prop.approximated", "Gradient strokes use the first gradient color"); colorValue = paint.gradient.colors[0] ?? primary(); }
      if (strokeWidth !== null) {
        outline.setAttribute("fill", "none"); outline.setAttribute("stroke", cssColor(colorValue)); outline.setAttribute("stroke-width", String(strokeWidth));
      } else {
        outline.setAttribute("fill", cssColor(colorValue));
        report("info", "prop.approximated", "trim without stroke renders the untrimmed shape");
      }
      if (trim && strokeWidth !== null) {
        outline.setAttribute("pathLength", "1");
        outline.setAttribute("stroke-dasharray", `${Math.max(0, trim[1] - trim[0])} 2`);
        outline.setAttribute("stroke-dashoffset", String(-trim[0]));
      }
      svg.appendChild(outline);
      element.appendChild(svg);
    });
  }

  function shapeOptions(reader) {
    let strokeWidth = null;
    const stroke = reader.string("stroke");
    if (stroke !== null && swiftDouble(stroke) !== null) strokeWidth = swiftDouble(stroke);
    let trim = null;
    if (typeof reader.raw("trim") === "number") trim = [reader.raw("trim"), 1];
    else if (reader.string("trim") !== null) {
      const parts = reader.string("trim").split(",");
      if (parts.length === 1) { const from = swiftDouble(parts[0]); if (from !== null && from >= 0 && from <= 1) trim = [from, 1]; }
      else if (parts.length === 2 && swiftDouble(parts[0]) !== null && swiftDouble(parts[1]) !== null) trim = [swiftDouble(parts[0]), swiftDouble(parts[1])];
    }
    return { strokeWidth, trim };
  }

  function ring(thickness, tint, track, progress, fixedSize = null) {
    const node = fixedSize ? new FixedNode(fixedSize, fixedSize) : new FlexibleNode();
    return leaf(node, (target, element) => {
      const { width, height } = target.frame;
      const svgNS = "http://www.w3.org/2000/svg";
      const svg = element.ownerDocument.createElementNS(svgNS, "svg");
      svg.setAttribute("width", String(width)); svg.setAttribute("height", String(height));
      Object.assign(svg.style, { position: "absolute", left: "0", top: "0", overflow: "visible" });
      const circle = (stroke, dash) => {
        const item = element.ownerDocument.createElementNS(svgNS, "circle");
        for (const [key, value] of Object.entries({ cx: width / 2, cy: height / 2, r: Math.min(width, height) / 2, fill: "none", stroke: cssColor(stroke), "stroke-width": thickness })) item.setAttribute(key, String(value));
        if (dash !== undefined) {
          item.setAttribute("pathLength", "1"); item.setAttribute("stroke-dasharray", `${dash} 2`);
          item.setAttribute("stroke-linecap", "round"); item.setAttribute("transform", `rotate(-90 ${width / 2} ${height / 2})`);
        }
        return item;
      };
      svg.appendChild(circle(track));
      if (progress > 0) svg.appendChild(circle(tint, progress));
      element.appendChild(svg);
    });
  }

  // MARK: Images

  /// ScriptWidgetPackage.getImage: image/<name>, trying common extensions.
  function packageImage(name) {
    const trimmed = name.trim();
    if (trimmed === "" || trimmed.includes("..")) return null;
    const base = `image/${trimmed}`;
    const candidates = /\.[A-Za-z0-9]+$/.test(trimmed) ? [base] : ["png", "jpg", "jpeg", "webp", "heic"].map((ext) => `${base}.${ext}`);
    for (const candidate of candidates) if (resources[candidate]) return { path: candidate, url: resources[candidate] };
    return null;
  }

  /// ScriptWidgetPackage.getGifFile: exact .gif, bare name + .gif, then a
  /// case-insensitive match in image/.
  function packageGif(name) {
    const trimmed = name.trim();
    if (trimmed === "" || trimmed.includes("..")) return null;
    const direct = `image/${trimmed}`;
    if (/\.gif$/i.test(trimmed) && resources[direct]) return resources[direct];
    if (!/\.[A-Za-z0-9]+$/.test(trimmed) && resources[`${direct}.gif`]) return resources[`${direct}.gif`];
    const target = trimmed.replace(/\.[^.]*$/, "").toLowerCase();
    for (const [path, url] of Object.entries(resources)) {
      if (!path.startsWith("image/") || !/\.gif$/i.test(path)) continue;
      const file = path.slice("image/".length).toLowerCase();
      if (file === trimmed.toLowerCase() || file.replace(/\.gif$/, "") === target) return url;
    }
    return null;
  }

  function drawPicture(url, fit) {
    return (node, element) => {
      const image = element.ownerDocument.createElement("img");
      image.src = url; image.alt = "";
      Object.assign(image.style, { position: "absolute", left: "0", top: "0", width: "100%", height: "100%", objectFit: fit });
      element.appendChild(image);
    };
  }

  // SF Symbols are fixed-size images about 1.2 em wide and one line tall.
  // They are drawn with the closest Lucide icon (ISC license).
  function glyph(systemName, font, inputPaint) {
    const paint = inputPaint ?? { color: primary() };
    const style = textStyleFor(font);
    // "x.circle.fill" / "x.square.fill": a filled container with the inner
    // symbol cut out of it.
    const containerMatch = /^(.+)\.(circle|square)\.fill$/.exec(systemName);
    const container = containerMatch?.[2] ?? null;
    const icon = container ? (lucideIconFor(containerMatch[1]) ?? []) : lucideIconFor(systemName);
    if (icon) report("info", "icon.approximated", `SF Symbol "${systemName}" is drawn with an open-source look-alike icon`);
    else report("warning", "icon.unmapped", `SF Symbol "${systemName}" has no web icon yet; a placeholder is shown`);
    // Real SF Symbol proportions when known (symbolMetrics.generated.js).
    const ratio = symbolMetrics[systemName] ?? symbolMetrics[systemName.replace(/\.fill(?=\.|$)/g, "")];
    const half = (value) => Math.round(value * 2) / 2;
    const box = ratio ? [half(style.size * ratio[0]), half(style.size * ratio[1])] : [Math.ceil(style.size * 1.2 * 2) / 2, style.natural];
    const fixed = new FixedNode(box[0], box[1]);
    // SF Symbols take part in text spacing (see defaultSpacing).
    const symbolEdge = { symbol: true, size: style.size };
    fixed.edge = () => symbolEdge;
    const node = leaf(fixed, (target, element) => {
      const { width, height } = target.frame;
      const colorValue = cssColor(paint.color ?? paint.gradient?.colors[0] ?? primary());
      if (!icon) {
        Object.assign(element.style, { fontFamily: style.family, fontSize: `${style.size * 0.9}px`, lineHeight: `${height}px`, textAlign: "center", color: colorValue });
        element.textContent = "◉";
        return;
      }
      const svgNS = "http://www.w3.org/2000/svg";
      const side = Math.min(style.size * 1.08, Math.max(width, height));
      const svg = element.ownerDocument.createElementNS(svgNS, "svg");
      for (const [key, value] of Object.entries({ width: side, height: side, viewBox: "0 0 24 24", fill: "none", stroke: colorValue,
        "stroke-width": String(Math.max(1.5, Math.min(3, 1.4 + (style.weight - 100) / 400))), "stroke-linecap": "round", "stroke-linejoin": "round" })) svg.setAttribute(key, String(value));
      Object.assign(svg.style, { position: "absolute", left: `${(width - side) / 2}px`, top: `${(height - side) / 2}px` });
      const shape = symbolShapes[systemName];
      if (shape) {
        svg.setAttribute("fill", "currentColor"); svg.setAttribute("stroke", "none");
        Object.assign(svg.style, { color: colorValue, overflow: "visible" });
        svg.innerHTML = shape(`sw-cut-${++maskCounter}`);
        element.appendChild(svg);
        return;
      }
      if (container) {
        const id = `sw-cut-${++maskCounter}`;
        const strokeWidth = Number(svg.getAttribute("stroke-width"));
        svg.innerHTML = `<defs><mask id="${id}" maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24"><rect width="24" height="24" fill="white"/>`
          + `<g transform="translate(12 12) scale(0.58) translate(-12 -12)" stroke="black" fill="none" stroke-width="${strokeWidth * 1.45}"></g></mask></defs>`
          + (container === "circle" ? `<circle cx="12" cy="12" r="11" stroke="none" fill="${colorValue}" mask="url(#${id})"/>` : `<rect x="1.5" y="1.5" width="21" height="21" rx="5" stroke="none" fill="${colorValue}" mask="url(#${id})"/>`);
        const cut = svg.querySelector("g");
        for (const [tag, attributes] of icon) {
          const item = element.ownerDocument.createElementNS(svgNS, tag);
          for (const [key, value] of Object.entries(attributes)) item.setAttribute(key, String(value));
          cut.appendChild(item);
        }
        element.appendChild(svg);
        return;
      }
      // Lucide's plane points up and to the right and its quote closes; SF
      // draws airplane level and quote.opening as an opening mark.
      const turn = { airplane: 45, "airplane.departure": 0, "quote.opening": 180 }[systemName];
      if (turn) svg.style.transform = `rotate(${turn}deg)`;
      // SF ".fill" variants are solid: fill the icon's closed shapes.
      const filled = /\.fill(\.|$)/.test(systemName);
      for (const [tag, attributes] of icon) {
        const item = element.ownerDocument.createElementNS(svgNS, tag);
        for (const [key, value] of Object.entries(attributes)) item.setAttribute(key, String(value));
        const closed = tag === "circle" || tag === "rect" || tag === "ellipse" || tag === "polygon" || (tag === "path" && closedPath(attributes.d ?? ""));
        if (filled && closed) item.setAttribute("fill", colorValue);
        svg.appendChild(item);
      }
      element.appendChild(svg);
    });
    node.title = systemName;
    return node;
  }

  function imageNode(reader) {
    const systemName = reader.string("systemName");
    const name = reader.string("name", "id");
    const url = reader.string("url", "src");
    const mode = reader.string("mode");
    if (systemName === null && name !== null) {
      const found = packageImage(name);
      if (found) {
        if (/\.heic$/i.test(found.path)) report("warning", "image.format", `HEIC image ${found.path} may not display in this browser`);
        const prepared = /\.gif$/i.test(found.path) ? preparedGifs.get(found.url) : undefined;
        if (/\.gif$/i.test(found.path) && !prepared?.firstFrame) return text("GIF unavailable",defaultFont(),null);
        const imageURL = prepared?.firstFrame ?? found.url;
        const natural = imageSizes.get(imageURL) ?? [10, 10];
        if (mode === "fit" || mode === "fill") return leaf(new AspectNode(natural, reader.double("ratio"), mode), drawPicture(imageURL, mode === "fill" ? "cover" : "contain"));
        return leaf(new FlexibleNode(natural), drawPicture(imageURL, "fill"));
      }
      report("warning", "image.missing", `Package image "${name}" was not found in image/`);
    }
    const drawable = systemName === null && url !== null ? drawableURL(url) : null;
    if (drawable) {
      const natural = imageSizes.get(drawable) ?? [10, 10];
      return leaf(new FixedNode(...natural), drawPicture(drawable, "fill"));
    }
    if (systemName === null && url !== null) report("warning", "image.remote", `Remote image ${url.slice(0, 80)} is not loaded by the web preview`);
    return glyph(systemName ?? "questionmark.circle", elementFont(reader), null);
  }

  // MARK: Stacks

  // Measured on iOS 27: HStack children are 8 apart. In a VStack, text to
  // text adds the lower text's leading; between text and other views see
  // below. Spacers add no spacing.
  // On macOS 26 text to text adds only the lower font's leading, text above
  // another view 0.4729 x size and a view above text 0.2109 x size, both
  // plus a half-point step of about 0.118 x size.
  function defaultSpacing(axis) {
    return (previous, next) => {
      if (previous.isSpacer || next.isSpacer) return 0;
      if (axis === "h") return 8;
      const above = previous.edge("bottom"); const below = next.edge("top");
      const half = (value) => Math.round(value * 2) / 2;
      // SF Symbols sit flush against text and other symbols; next to other
      // views they leave 0.135 x size (+1 below the symbol), measured on iOS.
      if (above?.symbol || below?.symbol) {
        if (above && below) return 0;
        if (above) return half(0.135 * above.size + 1);
        return Math.ceil(0.1354 * below.size * 2) / 2;
      }
      if (platform() === "macos") {
        const step = (size) => Math.ceil(0.118 * size * 2) / 2;
        if (above && below) return below.gap ?? 0;
        if (above) return half(0.4729 * above.size + step(above.size));
        if (below) return half(0.2109 * below.size + step(below.size));
        return 8;
      }
      // Text to text: the lower text's Dynamic Type leading (its style line
      // height minus the natural height, up to the half point); sized fonts
      // have none.
      if (above && below) return below.textStyle ? Math.max(0, Math.ceil((below.lineHeight - below.size * naturalLineRatio) * 2) / 2) : 0;
      // Text above another view leaves 0.6094 x its size, a view above text
      // 0.3625 x the text's size (measured at 8x for sizes 1...80), which
      // snaps up to the half point.
      if (above) return half(0.6094 * above.size);
      if (below) return Math.ceil(0.3625 * below.size * 2) / 2;
      return 8;
    };
  }

  function stack(axis, children, reader) {
    const alignment = reader.string("alignment");
    const cross = axis === "v"
      ? ({ leading: "start", trailing: "end" }[alignment] ?? "center")
      : ({ top: "start", bottom: "end", firstTextBaseline: "start", lastTextBaseline: "end" }[alignment] ?? "center");
    const explicit = reader.double("spacing");
    return new StackNode(axis, children, { alignment: cross, spacing: explicit !== null ? () => explicit : defaultSpacing(axis) });
  }

  /// Fragments are SwiftUI Groups: their children join the parent layout.
  function buildChildren(element, axis) {
    const result = [];
    for (const child of childrenAsElements(element)) {
      if (child.tag === "Fragment") result.push(...buildChildren(child, axis));
      else result.push(build(child, axis));
    }
    return result;
  }

  // MARK: General modifiers (ScriptWidgetAttributeGeneralModifier order)

  function applyGeneral(content, element, reader, { isRoot = false } = {}) {
    let node = content;
    const padding = parsePadding(reader);
    if (padding) node = new PaddingNode(node, padding);
    const frame = parseFrame(reader);
    if (frame.mode !== "none") node = new FrameNode(node, { ...frame, alignment: alignments[frame.alignment] ?? alignments.center });

    const decoration = {};
    const background = reader.string("background");
    if (background !== null && !isRoot) {
      const paint = parsePaint(background, appearance);
      if (paint) decoration.background = paint;
    }
    const material = reader.string("backgroundMaterial");
    if (!isRoot && ["ultraThin", "thin", "regular", "thick", "ultraThick"].includes(material)) {
      decoration.material = material;
      decoration.materialFallback = parsePaint(background, appearance);
      delete decoration.background;
    }
    const corner = reader.double("corner");
    if (corner !== null) decoration.cornerRadius = corner;
    let clipShape = reader.int("clip") === 1 ? "" : null;
    if (reader.string("clip") !== null) clipShape = reader.string("clip");
    if (clipShape !== null) decoration.clip = clipShape;
    const opacity = reader.double("opacity");
    if (opacity !== null) decoration.opacity = Math.max(0, Math.min(1, opacity));
    // The macOS widget compiles ScriptWidgetAttributeAnimationModifier to a
    // static standard-clock poses; custom effects and JSON errors stay no-op.
    const parsedAnimation = parseAnimation(reader.string("animation"));
    const animation = platform() === "macos" ? (clockPeriods[parsedAnimation?.type] ? parsedAnimation : null) : parsedAnimation;
    if (platform() === "macos" && reader.string("animation") !== null) report("info", "animation.macos", "Mac shows static clock poses; other animations remain at rest");
    if (animation?.type === "error") return text("animation json error", defaultFont(), null);
    if (animation) {
      // The animation modifier sits between opacity and rotation, so it
      // gets its own layer: CSS animations own the transform property.
      if (Object.keys(decoration).length) node = new DecorationNode(node, { ...decoration, keepsEdges: !padding && frame.mode === "none" });
      node = new DecorationNode(node, { animation, keepsEdges: true });
      for (const key of Object.keys(decoration)) delete decoration[key];
    }
    const transforms = [];
    const rotation = reader.double("rotation");
    if (rotation !== null) transforms.push(`rotate(${rotation}deg)`);
    const rotation3d = reader.string("rotation3d");
    if (rotation3d !== null && !reduceMotion) {
      const rotation = parseRotation3D(rotation3d);
      if (rotation) transforms.push(`perspective(400px) rotate3d(${rotation.x}, ${rotation.y}, ${rotation.z}, ${rotation.degree}deg)`);
    }
    if (transforms.length) decoration.transform = transforms.join(" ");
    const shadow = reader.string("shadow");
    if (shadow !== null) {
      const parts = shadow.split(",");
      let shadowColor = null; let radius = 3; let x = 0; let y = 3;
      if (parts.length === 1) shadowColor = color(shadow);
      else if (parts.length === 4) {
        shadowColor = color(parts[0]);
        radius = swiftDouble(parts[1]) ?? radius; x = swiftDouble(parts[2]) ?? x; y = swiftDouble(parts[3]) ?? y;
      }
      if (shadowColor) decoration.filter = `drop-shadow(${x}px ${y}px ${radius / 2}px ${cssColor(shadowColor)})`;
    }
    if (reader.bool("widgetAccentable") === true) decoration.accentable = true;
    if (Object.keys(decoration).length) {
      // Backgrounds and effects keep the content's spacing preferences;
      // padding and frames replace them.
      decoration.keepsEdges = !padding && frame.mode === "none";
      node = new DecorationNode(node, decoration);
    }
    return node;
  }

  // MARK: Animations (ScriptWidgetAttributeAnimationModifier)

  function parseAnimation(value) {
    if (value === null) return null;
    if (value.startsWith("animation:")) {
      let json;
      try { json = JSON.parse(value.slice("animation:".length), (_, value) => { if (typeof value === "number" && !Number.isFinite(value)) throw new Error("Invalid animation number"); return value; }); } catch { return { type: "error" }; }
      const type = typeof json?.type === "string" ? json.type : "";
      if (type === "clock") {
        return { type, timezone: typeof json.timezone === "string" ? json.timezone : "current", anchor: typeof json.anchor === "string" ? json.anchor : "center", interval: typeof json.interval === "number" ? clockPeriod(json.interval) : 10 };
      }
      if (type === "swing") return { type, duration: swingDuration(json.duration), direction: json.direction === "horizontal" ? "horizontal" : json.direction === undefined ? "horizontal" : "vertical", distance: swingDistance(json.distance) };
      return clockPeriods[type] ? { type, timezone: typeof json.timezone === "string" ? json.timezone : "current", anchor: typeof json.anchor === "string" ? json.anchor : "center" } : null;
    }
    const parts = value.split(",").filter((part) => part !== "");
    if (parts.length === 1) return clockPeriods[value] || value === "swing" ? (value === "swing" ? { type: "swing", duration: 1, direction: "horizontal", distance: 10 } : { type: value, timezone: "current", anchor: "center" }) : null;
    if (parts.length === 2 && parts[0].trim() === "clockCustom" && swiftDouble(parts[1].trim()) !== null) return { type: "clock", timezone: "current", anchor: "center", interval: clockPeriod(swiftDouble(parts[1].trim())) };
    return null;
  }

  // MARK: Tags

  function build(element, axis = "z", { isRoot = false } = {}) {
    const reader = propReader(element.props);
    checkProps(element, reader);
    const tag = element.tag;
    let content;
    switch (tag) {
      case "vstack": content = stack("v", buildChildren(element, "v"), reader); break;
      case "hstack": content = stack("h", buildChildren(element, "h"), reader); break;
      case "zstack": content = new ZStackNode(buildChildren(element, "z")); break;
      case "text": case "date": {
        const font = elementFont(reader);
        const align = { leading: "left", center: "center", trailing: "right" }[reader.string("alignment")] ?? "left";
        if (tag === "date") report("info", "tag.approximated", "<date> uses English formats; timers show the value at render time");
        content = text(tag === "date" ? formatDate(reader) : textFromChildren(element), font, paintOf(reader, "color"), align);
        break;
      }
      case "spacer": {
        const spacer = new SpacerNode(axis);
        const frame = parseFrame(reader);
        return frame.mode === "none" ? spacer : new FrameNode(spacer, { ...frame, alignment: alignments[frame.alignment] ?? alignments.center });
      }
      case "rect": {
        const corner = reader.string("corner");
        const radius = corner !== null ? swiftDouble(corner) : null;
        content = shape(radius !== null ? "rounded" : "rect", paintOf(reader, "color") ?? { color: primary() }, { ...shapeOptions(reader), cornerRadius: radius ?? 0 });
        break;
      }
      case "capsule": case "ellipse": case "circle":
        content = shape(tag, paintOf(reader, "color") ?? { color: primary() }, shapeOptions(reader)); break;
      case "roundedrect":
        content = shape("rounded", { color: color(reader.string("color") ?? "#e2e8f0") ?? color("gray") }, { cornerRadius: reader.double("radius") ?? 12 }); break;
      case "divider": case "line": {
        const thickness = reader.double("thickness") ?? (tag === "divider" ? 1 : 2);
        const fill = { color: color(reader.string("color") ?? "secondary") ?? color("secondary") };
        const vertical = reader.string("axis") === "vertical";
        const length = reader.double("length") ?? 48;
        const frame = tag === "line"
          ? { mode: "size", width: vertical ? thickness : length, height: vertical ? length : thickness }
          : vertical ? { mode: "width", width: thickness } : { mode: "height", height: thickness };
        content = new FrameNode(shape("rect", fill), { ...frame, alignment: alignments.center });
        break;
      }
      case "icon": {
        const base = reader.double("size") !== null ? { ...defaultFont(), natural: undefined, gap: undefined, lineHeight: null, size: reader.double("size") } : defaultFont();
        content = glyph(reader.string("systemName") ?? "questionmark.circle", elementFont(reader, base), paintOf(reader, "color"));
        break;
      }
      case "image": content = imageNode(reader); break;
      case "gif": {
        const url = packageGif(reader.string("file") ?? "");
        if (url && preparedGifs.get(url)?.url) { report("info", "tag.approximated", "<gif> uses bounded browser playback or a static frame; native WidgetKit timing differs"); content = leaf(new FlexibleNode(), drawPicture(preparedGifs.get(url).url, "contain")); }
        else content = text("GIF unavailable", defaultFont(), null);
        break;
      }
      case "label": {
        const font = elementFont(reader);
        const paint = paintOf(reader, "color");
        content = new StackNode("h", [glyph(reader.string("systemName") ?? "circle.fill", font, paint), text(reader.string("title") ?? textFromChildren(element), font, paint)], { alignment: "center", spacing: () => 8 });
        break;
      }
      case "badge": case "chip": {
        const isBadge = tag === "badge";
        const font = styleFont(isBadge ? "caption2" : "caption");
        const textColor = reader.string("color") !== null ? color(reader.string("color")) : color(isBadge ? "#e2e8f0" : "#0f172a");
        const padded = new PaddingNode(text(reader.string("text") ?? textFromChildren(element), font, { color: textColor ?? [0, 0, 0, 0] }), isBadge ? [4, 8, 4, 8] : [5, 10, 5, 10]);
        const decoration = { cornerRadius: reader.double("radius") ?? (isBadge ? 6 : 14) };
        if (reader.string("background") === null) decoration.background = { color: color(isBadge ? "#0f172a" : "#f1f5f9") };
        if (!isBadge) decoration.border = color(reader.string("borderColor") ?? "#cbd5f5") ?? color("gray");
        content = new DecorationNode(padded, decoration);
        break;
      }
      case "stat": {
        const muted = { color: color(reader.string("mutedColor") ?? "#64748b") ?? color("gray") };
        const children = [text(reader.string("title") ?? "Title", styleFont("caption"), muted), text(reader.string("value") ?? "0", styleFont("title3"), { color: color(reader.string("color") ?? "#0f172a") ?? color("black") })];
        const subtitle = reader.string("subtitle") ?? "";
        if (subtitle) children.push(text(subtitle, styleFont("caption2"), muted));
        content = new StackNode("v", children, { alignment: "start", spacing: () => 4 });
        break;
      }
      case "progress": content = progressNode(reader); break;
      case "ring": {
        const value = Math.min(Math.max(reader.double("value") ?? 0, 0), 1);
        content = ring(reader.double("thickness") ?? 8, color(reader.string("color") ?? "#3b82f6") ?? color("blue"), color(reader.string("trackColor") ?? "#e2e8f0") ?? [142, 142, 147, 0.2], value);
        break;
      }
      case "link": case "button": case "toggle": {
        const outerTint = tint;
        const macButton = tag === "button" && platform() === "macos";
        if (tag === "button" && !macButton) tint = color("blue");
        const macToggle = tag === "toggle" && platform() === "macos";
        // macOS styles a toggle's label like a checkbox title and subtitle:
        // the first view in label color (85% primary), the rest secondary.
        const labelColor = appearance === "dark" ? [255, 255, 255, 0.85] : [0, 0, 0, 0.85];
        const children = macToggle
          ? childrenAsElements(element).map((child, index) => { tint = index === 0 ? labelColor : color("secondary"); return build(child, "v"); })
          : buildChildren(element, "v");
        tint = outerTint;
        if (macToggle) {
          // A 16-point checkbox (measured on macOS 27) 6 points before the label.
          const on = reader.bool("on") ?? false;
          report("info", "tag.approximated", "<toggle> is drawn as a static checkbox");
          const box = leaf(new FixedNode(16, 16), (node, target) => {
            Object.assign(target.style, { borderRadius: "4px", backgroundColor: cssColor(on ? [0, 133, 249, 1] : appearance === "dark" ? [255, 255, 255, 0.1] : [230, 230, 230, 1]) });
            if (!on) return;
            target.innerHTML = '<svg width="16" height="16" viewBox="0 0 16 16" style="position:absolute;left:0;top:0"><path d="M4.4 8.4 L7 11 L11.8 5" fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
          });
          content = new StackNode("h", [box, new StackNode("v", children, { alignment: "start", spacing: defaultSpacing("v") })], { alignment: "center", spacing: () => 6 });
        } else if (tag === "toggle") {
          const on = reader.bool("on") ?? false;
          report("info", "tag.approximated", "<toggle> is drawn as a static switch");
          const knob = leaf(new FixedNode(51, 31), (node, target) => {
            Object.assign(target.style, { borderRadius: "16px", backgroundColor: cssColor(on ? color("green") : [120, 120, 128, 0.16]) });
            const thumb = target.ownerDocument.createElement("div");
            Object.assign(thumb.style, { position: "absolute", top: "2px", left: on ? "22px" : "2px", width: "27px", height: "27px", borderRadius: "14px", backgroundColor: "white", boxShadow: "0 1px 3px rgba(0,0,0,0.25)" });
            target.appendChild(thumb);
          });
          content = new StackNode("h", [new StackNode("v", children, { alignment: "start", spacing: defaultSpacing("v") }), new SpacerNode("h"), knob], { alignment: "center", spacing: () => 8 });
        } else {
          if (tag === "button") report("info", "tag.approximated", "<button> renders its label; taps run only on iPhone");
          // The label views sit side by side, as SwiftUI lays out a Button's
          // label content.
          content = new StackNode(tag === "button" ? "h" : "v", children, { alignment: "center", spacing: defaultSpacing(tag === "button" ? "h" : "v") });
          // macOS draws the automatic (bordered) style: a 5-point rounded
          // bezel of 7.45% primary around 4 x 12 points of padding.
          if (macButton) {
            const bezel = appearance === "dark" ? [255, 255, 255, 0.0745] : [0, 0, 0, 0.0745];
            content = new DecorationNode(new PaddingNode(content, [4, 12, 4, 12]), { background: { color: bezel }, cornerRadius: 5 });
          }
        }
        break;
      }
      case "hgrid": case "vgrid": content = gridNode(element, reader, tag === "vgrid" ? "v" : "h"); break;
      case "gauge": content = gaugeNode(reader); break;
      case "chart": content = chartNode(reader); break;
      case "Fragment": {
        const children = buildChildren(element, axis);
        return children.length === 1 ? children[0] : new StackNode("v", children, { alignment: "center", spacing: defaultSpacing("v") });
      }
      default: {
        report("warning", "tag.unknown", tag === null ? "Element has a non-string tag" : `Unknown tag <${tag}> renders as "UnknownTagName" on iPhone`);
        return new DecorationNode(text(tag === null ? "UnknownTagType" : "UnknownTagName", defaultFont(), null), { background: { color: color(tag === null ? "purple" : "pink") } });
      }
    }
    const result = applyGeneral(content, element, reader, { isRoot });
    const interaction = interactionFor(tag, reader);
    if (interaction) result.interaction = interaction;
    if (tag === "date") result.dateText = dateDescription(reader);
    return result;
  }

  // What a tap on this view does, for hosts that deliver taps (Android). The
  // web preview only records it as data attributes.
  function interactionFor(tag, reader) {
    const text = (name) => reader.string(name);
    if (tag === "link") return text("url") !== null ? { type: "link", url: text("url") } : null;
    // onClick names a function in the entry script (ButtonActionAppIntent).
    if (tag === "button") return { type: "button", action: text("action"), actionID: text("actionID"), handler: text("onClick") };
    if (tag === "toggle") return { type: "toggle", on: reader.bool("on") ?? false, actionID: text("actionID"), stateKey: text("stateKey"), handler: text("onClick") };
    return text("linkurl") !== null ? { type: "link", url: text("linkurl") } : null;
  }

  // The style and target instant of a <date>, so a host with self-updating
  // text views can keep timers and clocks current between renders.
  function dateDescription(reader) {
    return { style: reader.string("style") ?? "timer", date: reader.string("date") ?? reader.double("date") };
  }

  function progressNode(reader) {
    const value = Math.max(reader.double("value") ?? 0, 0);
    const total = Math.max(reader.double("total") ?? 1, 0.000001);
    const progress = Math.min(value / total, 1);
    const label = reader.string("label") ?? "";
    const tint = color(reader.string("color") ?? "#3b82f6") ?? color("blue");
    const track = (reader.string("trackColor") !== null ? color(reader.string("trackColor")) : null) ?? [255, 255, 255, 0.15];
    const thickness = reader.double("thickness") ?? 6;
    if ((reader.string("style") ?? "linear") === "circular") {
      const side = reader.double("frame") ?? 32;
      const children = [ring(thickness, tint, track, progress, side)];
      if (label) children.push(text(label, styleFont("caption2"), null));
      return new FrameNode(new ZStackNode(children), { mode: "size", width: side, height: side, alignment: alignments.center });
    }
    const bar = leaf(new FlexibleNode(), (node, element) => {
      Object.assign(element.style, { borderRadius: `${thickness / 2}px`, backgroundColor: cssColor(track), overflow: "hidden" });
      const fill = element.ownerDocument.createElement("div");
      Object.assign(fill.style, { position: "absolute", left: "0", top: "0", height: "100%", width: `${node.frame.width * progress}px`, borderRadius: `${thickness / 2}px`, backgroundColor: cssColor(tint) });
      element.appendChild(fill);
    });
    const barFrame = new FrameNode(bar, { mode: "height", height: thickness, alignment: alignments.center });
    const children = label ? [text(label, styleFont("caption2"), null), barFrame] : [barFrame];
    return new StackNode("v", children, { alignment: "start", spacing: () => (label ? 4 : 0) });
  }

  // ScriptWidgetElementTagDate: Swift's Date() is the real clock, so the
  // web preview uses the real clock too; `now` (like ScriptWidgetRenderClock
  // in tests) fixes it for the absolute styles. Formats follow
  // Text(date, style:) in English.
  function formatDate(reader) {
    const style = { time: "time", date: "date", relative: "relative", offset: "offset", timer: "timer" }[reader.string("style") ?? "timer"] ?? "time";
    const real = new Date();
    const now = fixedNow !== null && (style === "time" || style === "date") ? new Date(fixedNow) : real;
    let date = now;
    const name = reader.string("date");
    if (name !== null) {
      if (name === "tomorrow") date = new Date(now.getTime() + 86400000);
      else if (name === "yesterday") date = new Date(now.getTime() - 86400000);
      else if (name === "start of today") date = new Date(now.getFullYear(), now.getMonth(), now.getDate());
      else if (name.startsWith("+") || name.startsWith("-")) {
        let step = 3600000 * (name.startsWith("+") ? 1 : -1);
        if (name.endsWith("d")) step *= 24;
        const middle = name.length >= 3 ? Number.parseInt(name.slice(1, -1), 10) : 0;
        date = new Date(now.getTime() + step * (Number.isFinite(middle) && /^[+-]?\d+$/.test(name.slice(1, -1)) ? middle : 0));
      }
    } else if (reader.double("date") !== null) date = new Date(reader.double("date"));
    const seconds = Math.round((date.getTime() - real.getTime()) / 1000);
    const parts = (value) => {
      const total = Math.abs(value);
      const days = Math.floor(total / 86400); const hours = Math.floor((total % 86400) / 3600); const minutes = Math.floor((total % 3600) / 60); const secs = total % 60;
      if (days) return hours ? `${days} day${days === 1 ? "" : "s"}, ${hours} hr` : `${days} day${days === 1 ? "" : "s"}`;
      if (hours) return minutes ? `${hours} hr, ${minutes} min` : `${hours} hr`;
      if (minutes) return secs ? `${minutes} min, ${secs} sec` : `${minutes} min`;
      return `${secs} sec`;
    };
    if (style === "time") return date.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
    if (style === "date") return date.toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" });
    if (style === "relative") return parts(seconds);
    if (style === "offset") return `${seconds >= 0 ? "+" : "-"}${parts(seconds)}`;
    const total = Math.abs(seconds);
    const hours = Math.floor(total / 3600); const minutes = Math.floor((total % 3600) / 60); const secs = total % 60;
    return hours ? `${hours}:${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}` : `${minutes}:${String(secs).padStart(2, "0")}`;
  }

  // MARK: Grids (ScriptWidgetElementTagGrid)

  function gridNode(element, reader, axis) {
    let items = [{ type: "adaptive", min: 30, max: null }];
    const columns = reader.string("columns");
    if (columns !== null) {
      try {
        const parsed = JSON.parse(columns);
        const stringValue = (value) => (typeof value === "string" ? value : typeof value === "number" ? String(value) : "");
        if (Array.isArray(parsed)) {
          items = parsed.map((item) => {
            const type = stringValue(item?.type);
            if (type === "fixed") return { type, value: Number.parseFloat(stringValue(item.value)) || 10 };
            if (type === "adaptive") {
              const min = swiftDouble(stringValue(item.min)) ?? 10;
              const max = swiftDouble(stringValue(item.max)) ?? 10;
              return { type, min, max: Math.max(min, max) };
            }
            return { type: "flexible" };
          });
        }
      } catch { /* native falls back to the default columns */ }
    }
    if (items.length === 0) items = [{ type: "flexible" }];
    return new GridNode(axis, buildChildren(element, axis), { items, spacing: reader.double("spacing") ?? 8, alignment: reader.string("alignment") });
  }

  // MARK: Gauges (ScriptWidgetElementTagGauge, MineGaugeView)

  function arcPath(cx, cy, r, from, to) {
    const point = (angle) => [cx + r * Math.cos((angle * Math.PI) / 180), cy + r * Math.sin((angle * Math.PI) / 180)];
    const [x0, y0] = point(from); const [x1, y1] = point(to);
    const large = Math.abs(to - from) > 180 ? 1 : 0;
    return `M ${x0} ${y0} A ${r} ${r} 0 ${large} 1 ${x1} ${y1}`;
  }

  function svgElement(parent, tag, attributes) {
    const item = parent.ownerDocument.createElementNS("http://www.w3.org/2000/svg", tag);
    for (const [key, value] of Object.entries(attributes)) item.setAttribute(key, String(value));
    parent.appendChild(item);
    return item;
  }

  function svgCanvas(element, width, height) {
    const svg = svgElement(element, "svg", { width, height, viewBox: `0 0 ${width} ${height}` });
    Object.assign(svg.style, { position: "absolute", left: "0", top: "0", overflow: "visible" });
    return svg;
  }

  function gaugeNode(reader) {
    const type = reader.string("type") ?? "original";
    if (type !== "original") return systemGauge(reader);
    let value = reader.string("value") !== null ? (swiftDouble(reader.string("value")) ?? 0.6) : 0.6;
    if (reader.double("value") !== null) value = reader.double("value");
    value = Math.min(value, 1);
    const angle = Math.min(reader.string("angle") !== null ? (swiftDouble(reader.string("angle")) ?? 260) : 260, 360);
    const thicknessText = reader.string("thickness");
    const thickness = thicknessText !== null && /^[+-]?\d+$/.test(thicknessText) ? Number(thicknessText) : 10;
    const fallback = primary();
    const needle = reader.string("needleColor") !== null ? (color(reader.string("needleColor")) ?? fallback) : fallback;
    let sections = [["green", 0.1], ["yellow", 0.1], ["orange", 0.1], ["red", 0.1], ["purple", 0.2], ["blue", 0.4]].map(([name, size]) => ({ color: color(name), value: size }));
    if (reader.string("sections") !== null) {
      try {
        const parsed = JSON.parse(reader.string("sections"));
        if (Array.isArray(parsed)) {
          let left = 100;
          sections = parsed.map((item) => {
            const stringValue = (raw) => (typeof raw === "string" ? raw : typeof raw === "number" ? String(raw) : "");
            let size = swiftDouble(stringValue(item?.value)) ?? 0;
            if (Math.trunc(size * 100) > left) size = 0;
            left -= Math.trunc(size * 100);
            return { color: color(stringValue(item?.color)) ?? fallback, value: size };
          });
        }
      } catch { /* keep defaults, as natively */ }
    }
    const start = 90 + (360 - angle) / 2;
    const arcs = leaf(new FlexibleNode(), (node, element) => {
      const { width, height } = node.frame;
      if (width <= 0 || height <= 0) return;
      const lineWidth = height / thickness;
      const radius = (Math.min(width, height) - lineWidth) / 2;
      const cx = width / 2; const cy = height / 2;
      const svg = svgCanvas(element, width, height);
      let covered = 0;
      sections.forEach((section, index) => {
        const from = start + covered * angle;
        const to = from + section.value * angle;
        if (section.value > 0) svgElement(svg, "path", { d: arcPath(cx, cy, radius, from, to), fill: "none", stroke: cssColor(section.color), "stroke-width": lineWidth });
        const capAngle = index === 0 ? from : index === sections.length - 1 ? start + angle : null;
        if (capAngle !== null) {
          const rad = (capAngle * Math.PI) / 180;
          svgElement(svg, "circle", { cx: cx + radius * Math.cos(rad), cy: cy + radius * Math.sin(rad), r: lineWidth / 2, fill: cssColor(section.color) });
        }
        covered += section.value;
      });
      const needleAngle = start + value * angle;
      const group = svgElement(svg, "g", { transform: `rotate(${needleAngle} ${cx} ${cy})` });
      const rectWidth = height / 2; const rectHeight = height / 20;
      svgElement(group, "rect", { x: cx, y: cy - rectHeight / 2, width: rectWidth, height: rectHeight, rx: Math.min(lineWidth / 2, rectHeight / 2), fill: cssColor([needle[0], needle[1], needle[2], needle[3] * 0.8]) });
      svgElement(svg, "circle", { cx, cy, r: lineWidth / 2, fill: cssColor(needle) });
    });
    const labelFont = parseFont(reader.string("labelFont")) ?? defaultFont();
    // Native quirk: the default label is computed before `value` is read.
    const label = text(reader.string("label") ?? "60%", labelFont, paintOf(reader, "labelColor"));
    const title = text(reader.string("title") ?? "", labelFont, paintOf(reader, "titleColor"));
    return new BottomOverlayNode(arcs, new StackNode("v", [label, title], { alignment: "center", spacing: defaultSpacing("v") }));
  }

  function systemGauge(reader) {
    report("info", "tag.approximated", "<gauge type> system styles are approximated");
    const value = Math.max(0, Math.min(1, swiftDouble(reader.string("value") ?? "0.6") ?? 0.6));
    const style = reader.string("style") ?? "circular";
    const label = reader.string("text") ?? ""; const current = reader.string("current") ?? "";
    const min = reader.string("min") ?? ""; const max = reader.string("max") ?? "";
    const tintColor = cssColor(primary());
    const background = cssColor(systemBackground(appearance));
    if (style === "linear") {
      // accessoryLinear: a solid capsule with a ring marker; min/max labels
      // at the ends; the title label is not shown.
      const bar = leaf(new FlexibleNode([100, 8]), (node, element) => {
        const { width, height } = node.frame;
        const svg = svgCanvas(element, width, height);
        svgElement(svg, "line", { x1: 4, x2: width - 4, y1: height / 2, y2: height / 2, stroke: tintColor, "stroke-width": 6, "stroke-linecap": "round" });
        const x = 4 + value * Math.max(0, width - 8);
        svgElement(svg, "circle", { cx: x, cy: height / 2, r: 5, fill: tintColor, stroke: background, "stroke-width": 2 });
      });
      const row = [];
      if (min) row.push(text(min, styleFont("body"), null));
      row.push(new FrameNode(bar, { mode: "height", height: 12, alignment: alignments.center }));
      if (max) row.push(text(max, styleFont("body"), null));
      return new StackNode("h", row, { alignment: "center", spacing: () => 6 });
    }
    const ringLeaf = leaf(new FixedNode(58, 58), (node, element) => {
      const svg = svgCanvas(element, 58, 58);
      const radius = 25; const start = 135; const sweep = 270;
      svgElement(svg, "path", { d: arcPath(29, 29, radius, start, start + sweep), fill: "none", stroke: tintColor, "stroke-width": 5, "stroke-linecap": "round" });
      const angle = ((start + sweep * value) * Math.PI) / 180;
      svgElement(svg, "circle", { cx: 29 + radius * Math.cos(angle), cy: 29 + radius * Math.sin(angle), r: 3.5, fill: background, stroke: tintColor, "stroke-width": 1.5 });
    });
    const centerLabel = text(current, { size: 22, lineHeight: null, weight: 500, design: "default" }, null);
    const overlay = new ZStackNode([ringLeaf, centerLabel]);
    if (!label) return overlay;
    return new BottomOverlayNode(new FrameNode(overlay, { mode: "size", width: 58, height: 58, alignment: alignments.center }), text(label, styleFont("caption2"), null));
  }

  // MARK: Charts (ScriptWidgetElementTagChart, Swift Charts approximation)

  const chartPalette = ["blue", "green", "orange", "purple", "red", "cyan", "yellow", "brown"];

  function chartNode(reader) {
    report("info", "tag.approximated", "<chart> is drawn with an SVG approximation of Swift Charts");
    const type = reader.string("type") ?? "bar";
    const data = reader.string("data") ?? "";
    if (data === "") return text("#chart no data#", defaultFont(), null);
    let items;
    try { items = JSON.parse(data); } catch { return text("#chart data json invalid#", defaultFont(), null); }
    const gantt = type === "bar-gantt"; const rule = type === "rule-x";
    const valid = Array.isArray(items) && items.every((item) => item && typeof item === "object" && (gantt
      ? typeof item.job === "string" && typeof item.start === "number" && typeof item.end === "number"
      : rule ? typeof item.xstart === "number" && typeof item.xend === "number" && typeof item.y === "number"
        : typeof item.label === "string" && typeof item.value === "number"));
    if (!["bar", "bar-x", "bar-y", "bar-gantt", "line", "point", "line-point", "area", "rect", "rule-x"].includes(type)) return text("#unknown chart type#", defaultFont(), null);
    if (!valid) return text("#chart data json invalid#", defaultFont(), null);
    const categoryEnabled = reader.bool("category") ?? false;
    const hideLegend = reader.bool("hideLegend") ?? false;
    const hideX = reader.bool("hideXAxis") ?? false; const hideY = reader.bool("hideYAxis") ?? false;
    const foreground = paintOf(reader, "color")?.color ?? color("blue");
    const categories = categoryEnabled ? [...new Set(items.map((item) => item.category ?? "null"))] : [];
    const colorFor = (item) => (categoryEnabled ? color(chartPalette[categories.indexOf(item.category ?? "null") % chartPalette.length]) : foreground);
    const axisColor = cssColor(color("secondary"));
    return leaf(new FlexibleNode([200, 120]), (node, element) => {
      const { width, height } = node.frame;
      const svg = svgCanvas(element, width, height);
      const legendHeight = categoryEnabled && !hideLegend ? 14 : 0;
      // Swift Charts starts the plot at the top edge and reserves a strip for
      // each axis (measured from iOS 27 and macOS 27 snapshots). iOS labels
      // use caption2 (11 pt) and may fill their whole band before truncating.
      const mac = platform() === "macos";
      const metrics = mac
        ? { top: 0, bottom: 0, xLabels: 18, yLabels: 20.5, yGap: 5, baseline: 14.5, yBaseline: 3.5, tick: 17.5, font: 10.5, labelBand: 0.9 }
        : { top: 0, bottom: 0, xLabels: 18, yLabels: 19, yGap: 6, baseline: 14, yBaseline: 3, tick: 16, font: 11, labelBand: 1 };
      const xLabelHeight = hideX ? 0 : metrics.xLabels;
      const yLabelWidth = hideY ? 0 : metrics.yLabels;
      const plot = { x: 0, y: metrics.top, width: Math.max(1, width - yLabelWidth), height: Math.max(1, height - xLabelHeight - legendHeight - metrics.top - metrics.bottom) };
      const textAt = (x, y, value, anchor = "middle") => {
        const label = svgElement(svg, "text", { x, y, "text-anchor": anchor, fill: axisColor, "font-size": metrics.font, "font-family": fontFamily(defaultFont()) });
        label.textContent = value;
        return label;
      };
      const values = gantt ? items.flatMap((item) => [item.start, item.end]) : rule ? items.flatMap((item) => [item.xstart, item.xend]) : items.map((item) => item.value);
      const stacked = type === "bar" ? Object.values(items.reduce((sums, item) => { sums[item.label] = (sums[item.label] ?? 0) + Math.max(0, item.value); return sums; }, {})) : [];
      const maxValue = Math.max(1e-9, ...values, ...stacked, 0);
      // Swift Charts picks 1/2/5 x 10^k steps with at most four intervals
      // (9 -> 0, 5, 10; 12 -> 0, 5, 10, 15; 40 -> 0, 10, ... 40). With the
      // value axis hidden the domain ends at the largest value.
      const magnitude = 10 ** Math.floor(Math.log10(maxValue));
      const tickStep = [0.1, 0.2, 0.5, 1, 2, 5, 10].map((factor) => factor * magnitude).find((candidate) => Math.ceil(maxValue / candidate - 1e-9) <= 4) ?? magnitude * 10;
      const valueAxisHidden = ["bar-x", "bar-y", "bar-gantt", "rule-x"].includes(type) ? hideX : hideY;
      const niceMax = valueAxisHidden ? maxValue : Math.ceil(maxValue / tickStep - 1e-9) * tickStep;
      const ticks = Array.from({ length: Math.round(niceMax / tickStep) + 1 }, (_, index) => index * tickStep);
      if (type === "bar" || type === "line" || type === "point" || type === "line-point" || type === "area" || type === "rect") {
        if (!hideY) for (const tick of ticks) {
          const y = plot.y + plot.height - (tick / niceMax) * plot.height;
          svgElement(svg, "line", { x1: plot.x, x2: plot.x + plot.width, y1: y, y2: y, stroke: axisColor, "stroke-opacity": 0.35 });
          textAt(plot.x + plot.width + metrics.yGap, y + metrics.yBaseline, Number(tick.toPrecision(3)).toString(), "start");
        }
        const labels = [...new Set(items.map((item) => item.label))];
        const band = plot.width / Math.max(1, labels.length);
        const xOf = (label) => plot.x + band * labels.indexOf(label) + band / 2;
        const yOf = (value) => plot.y + plot.height - (Math.max(0, value) / niceMax) * plot.height;
        if (!hideX) {
          // Swift Charts truncates category labels that do not fit their band.
          // Measured with the in-document measurer: the chart is drawn before
          // the widget is attached, so SVG text metrics are not available yet.
          const labelStyle = textStyleFor({ size: metrics.font, lineHeight: null, weight: 400, design: "default" });
          const labelWidth = (value) => measurer.measure(value, labelStyle, null).width;
          labels.forEach((label) => {
            const limit = band * metrics.labelBand;
            let shown = label;
            for (let length = label.length; length > 1 && labelWidth(shown) > limit; length -= 1) shown = `${label.slice(0, length - 1)}…`;
            textAt(xOf(label), plot.y + plot.height + metrics.baseline, shown);
          });
          for (let index = 0; index <= labels.length; index += 1) {
            const x = plot.x + band * index;
            svgElement(svg, "line", { x1: x, x2: x, y1: plot.y, y2: plot.y + plot.height + metrics.tick, stroke: axisColor, "stroke-opacity": 0.35, "stroke-dasharray": "2 2" });
          }
        }
        if (type === "bar" || type === "rect") {
          const offsets = {};
          for (const item of items) {
            const base = offsets[item.label] ?? 0;
            const top = base + Math.max(0, item.value);
            offsets[item.label] = top;
            svgElement(svg, "rect", { x: xOf(item.label) - band * 0.35, width: band * 0.7, y: yOf(top), height: Math.max(0, yOf(base) - yOf(top)), rx: 2, fill: cssColor(colorFor(item)) });
          }
        } else {
          const groups = categoryEnabled ? categories.map((category) => items.filter((item) => (item.category ?? "null") === category)) : [items];
          for (const group of groups) {
            if (!group.length) continue;
            const points = group.map((item) => [xOf(item.label), yOf(item.value)]);
            const stroke = cssColor(colorFor(group[0]));
            // AreaMark fills opaque and draws no line.
            if (type === "area") svgElement(svg, "path", { d: `M ${points[0][0]} ${plot.y + plot.height} ${points.map(([x, y]) => `L ${x} ${y}`).join(" ")} L ${points.at(-1)[0]} ${plot.y + plot.height} Z`, fill: stroke });
            else if (type !== "point") svgElement(svg, "polyline", { points: points.map((point) => point.join(",")).join(" "), fill: "none", stroke, "stroke-width": 2, "stroke-linejoin": "round" });
            if (type === "point" || type === "line-point") for (const [x, y] of points) svgElement(svg, "circle", { cx: x, cy: y, r: 3, fill: stroke });
          }
        }
      } else {
        const rows = gantt ? [...new Set(items.map((item) => item.job))] : rule ? [...new Set(items.map((item) => item.y))] : [null];
        const band = plot.height / Math.max(1, rows.length);
        const xOf = (value) => plot.x + (Math.max(0, value) / niceMax) * plot.width;
        if (!hideX) for (const tick of ticks) textAt(xOf(tick), plot.y + plot.height + 11, Number(tick.toPrecision(3)).toString());
        if (type === "bar-x" || type === "bar-y") {
          let offset = 0;
          for (const item of items) {
            const size = Math.max(0, item.value) / Math.max(1e-9, items.reduce((sum, entry) => sum + Math.max(0, entry.value), 0));
            if (type === "bar-x") svgElement(svg, "rect", { x: plot.x + offset * plot.width, y: plot.y, width: size * plot.width, height: plot.height, fill: cssColor(colorFor(item)) });
            else svgElement(svg, "rect", { x: plot.x, y: plot.y + plot.height - (offset + size) * plot.height, width: plot.width, height: size * plot.height, fill: cssColor(colorFor(item)) });
            offset += size;
          }
        } else {
          items.forEach((item) => {
            const row = rows.indexOf(gantt ? item.job : item.y);
            const y = plot.y + band * row;
            if (gantt) svgElement(svg, "rect", { x: xOf(item.start), width: Math.max(1, xOf(item.end) - xOf(item.start)), y: y + band * 0.15, height: band * 0.7, fill: cssColor(colorFor(item)) });
            else svgElement(svg, "line", { x1: xOf(item.xstart), x2: xOf(item.xend), y1: y + band / 2, y2: y + band / 2, stroke: cssColor(colorFor(item)), "stroke-width": 2 });
          });
        }
      }
      if (legendHeight) categories.forEach((category, index) => {
        const x = index * 60;
        svgElement(svg, "circle", { cx: x + 4, cy: height - 5, r: 3.5, fill: cssColor(color(chartPalette[index % chartPalette.length])) });
        textAt(x + 11, height - 1.5, category, "start");
      });
    });
  }

  // MARK: Drawing

  // Accented and vibrant modes (WidgetKit tinting) are approximated per
  // drawn leaf: content is desaturated; widgetAccentable content is tinted.
  const modeFilters = {
    accented: { plain: "grayscale(1) brightness(1.15)", accent: "grayscale(1) sepia(1) saturate(4) hue-rotate(175deg) brightness(1.1)" },
    vibrant: { plain: "grayscale(1) brightness(1.25)", accent: "grayscale(1) brightness(1.25)" },
  };

  // iOS SwiftUI puts each view's vertical origin on the 2x pixel grid in widget
  // coordinates (horizontal positions stay fractional: glyphs are placed
  // with subpixel precision). `origin` is the parent's absolute position.
  const snapToPixel = (value) => (platform() === "macos" ? value : Math.round(value * 2) / 2);
  function draw(node, parent, accented = false, origin = [0, 0]) {
    const element = doc.createElement("div");
    const { width, height } = node.frame;
    const absolute = [origin[0] + node.frame.x, snapToPixel(origin[1] + node.frame.y)];
    const x = absolute[0] - origin[0]; const y = absolute[1] - origin[1];
    Object.assign(element.style, { position: "absolute", left: `${x}px`, top: `${y}px`, width: `${width}px`, height: `${height}px` });
    let accent = accented;
    if (node instanceof DecorationNode) {
      accent ||= node.decoration.accentable === true;
      applyDecoration(element, node.decoration, width, height);
      if (modeFilters[renderingMode] && (node.decoration.background)) element.style.filter = [element.style.filter, modeFilters[renderingMode][accent ? "accent" : "plain"]].filter(Boolean).join(" ");
    }
    if (node.title) element.title = node.title;
    if (node.interaction) element.dataset.swInteraction = JSON.stringify(node.interaction);
    if (node.dateText) element.dataset.swDate = JSON.stringify(node.dateText);
    parent.appendChild(element);
    if (node.draw) {
      node.draw(node, element);
      if (modeFilters[renderingMode]) element.style.filter = modeFilters[renderingMode][accent ? "accent" : "plain"];
    }
    for (const child of node.children ?? (node.child ? [node.child] : [])) draw(child, element, accent, absolute);
  }

  function applyDecoration(element, decoration, width, height) {
    const style = element.style;
    if (decoration.material) paintMaterial(element, decoration.material, decoration.materialFallback, width, height);
    if (decoration.animation && (!reduceMotion || clockPeriods[decoration.animation.type])) {
      const animation = decoration.animation;
      const frozen = reduceMotion || platform() === "macos" || animations === "firstFrame" || fixedNow !== null || Number.isFinite(animationElapsed);
      if (animation.type === "swing") {
        const axis = animation.direction === "horizontal" ? "X" : "Y";
        style.setProperty("--sw-swing", `${swingDistance(animation.distance)}px`);
        style.transform = `translate${axis}(${swingPhase(Number.isFinite(animationElapsed) ? animationElapsed : 0, animation.duration, animation.distance)}px)`;
        if (!frozen) style.animation = `sw-swing-${axis} ${2 * swingDuration(animation.duration)}s linear infinite`;
      } else {
        const angle = clockPhase({ type: animation.type, interval: animation.interval, timezone: animation.timezone, date: fixedNow ?? Date.now() });
        const [ax, ay] = alignments[animation.anchor] ? { center: [0.5, 0.5], leading: [0, 0.5], trailing: [1, 0.5], top: [0.5, 0], bottom: [0.5, 1], topLeading: [0, 0], topTrailing: [1, 0], bottomLeading: [0, 1], bottomTrailing: [1, 1] }[animation.anchor] : [0.5, 0.5];
        style.transformOrigin = `${ax * 100}% ${ay * 100}%`;
        style.setProperty("--sw-start-angle", `${angle}deg`); style.transform = `rotate(${angle}deg)`;
        const period = animation.type === "clock" ? 2 * Math.abs(clockPeriod(animation.interval)) : clockPeriods[animation.type];
        // Extreme periods have no useful visible motion; retain the exact pose
        // rather than emitting an infinite or out-of-range CSS duration.
        if (!frozen && Number.isFinite(period) && period <= 31536000) {
          style.animation = `sw-clock ${period}s linear infinite`;
          if (animation.type === "clock" && animation.interval < 0) style.animationDirection = "reverse";
        }
      }
    }
    if (decoration.background?.color) style.backgroundColor = cssColor(decoration.background.color);
    else if (decoration.background?.gradient) style.backgroundImage = gradientCSS(decoration.background.gradient, width, height);
    if (decoration.cornerRadius !== undefined) { style.borderRadius = `${decoration.cornerRadius}px`; style.overflow = "hidden"; }
    if (decoration.clip !== undefined) {
      const path = { circle: "circle(closest-side at 50% 50%)", ellipse: "ellipse(50% 50% at 50% 50%)", capsule: "inset(0 round 9999px)" }[decoration.clip];
      if (path) style.clipPath = path; else style.overflow = "hidden";
    }
    if (decoration.opacity !== undefined) style.opacity = String(decoration.opacity);
    if (decoration.transform) style.transform = decoration.transform;
    if (decoration.filter) style.filter = decoration.filter;
    if (decoration.border) style.boxShadow = `inset 0 0 0 1px ${cssColor(decoration.border)}`;
    if (decoration.dashed) { style.border = "1px dashed rgba(127,127,127,0.8)"; style.boxSizing = "border-box"; }
  }

  // MARK: Widget container (ScriptWidgetWidgetElementRootView)

  let materialCount = 0;
  function paintMaterial(element, material, fallback, width, height) {
    const style = element.style;
    const opacities = { ultraThin: 0.3, thin: 0.46, regular: 0.65, thick: 0.8, ultraThick: 0.92 };
    if (!Object.hasOwn(opacities, material)) return;
    style.backgroundImage = "none";
    element.dataset.swMaterial = material;
    const css = doc.defaultView?.CSS;
    const cssSupported = css?.supports?.("backdrop-filter", "blur(1px)") || css?.supports?.("-webkit-backdrop-filter", "blur(1px)");
    materialCount += 1;
    if (renderingMode !== "fullColor") {
      style.backgroundColor = "transparent"; style.backgroundImage = "none";
      element.dataset.swMaterialFallback = "system";
      report("info", "material.system", "Local material is omitted in accented/vibrant mode; the system controls the widget background.");
    } else if (reduceTransparency || materialCount > 4 || cssSupported !== true) {
      style.backgroundColor = appearance === "dark" ? "black" : "white";
      if (fallback?.color) { const fill = cssColor(fallback.color); style.backgroundImage = `linear-gradient(${fill}, ${fill})`; }
      else if (fallback?.gradient) style.backgroundImage = gradientCSS(fallback.gradient, width, height);
      element.dataset.swMaterialFallback = "solid";
      report("info", "material.fallback", "Material uses an opaque background fallback (Reduce Transparency, unavailable CSS blur, or preview budget).");
    } else {
      style.backdropFilter = "blur(16px) saturate(140%)"; style.webkitBackdropFilter = style.backdropFilter;
      const component = appearance === "dark" ? 30 : 255;
      style.backgroundColor = `rgba(${component}, ${component}, ${component}, ${opacities[material]})`;
      report("info", "material.approximated", "CSS backdrop blur approximates SwiftUI material inside the widget; it does not reproduce system Liquid Glass or blur Home Screen wallpaper.");
    }
  }

  const previousPlatform = setPlatform(deviceProfiles[profile]?.platform ?? "ios");
  try {
    const rootNode = build(root, "z", { isRoot: root.tag !== "Fragment" });
    const [w, h] = rootNode.size(size.width, size.height);
    rootNode.place((size.width - w) / 2, (size.height - h) / 2, w, h);
    const widget = doc.createElement("div");
    widget.className = "sw-widget";
    widget.setAttribute("role", "img");
    widget.setAttribute("aria-label", "Widget preview");
    Object.assign(widget.style, { position: "relative", width: `${size.width}px`, height: `${size.height}px`, overflow: "hidden", backgroundColor: cssColor(systemBackground(appearance)), colorScheme: appearance });
    // iOS draws grayscale-antialiased glyphs; macOS font smoothing would
    // thicken stems by about 15%. macOS widgets keep the smoothing
    // (measured: text ink matches native exactly with it).
    if (platform() !== "macos") widget.style.webkitFontSmoothing = "antialiased";
    const rootPaint = parsePaint(propReader(root.props).string("background"), appearance);
    if (renderingMode === "fullColor" && !(lockScreen && family.startsWith("accessory"))) {
      if (rootPaint?.color) widget.style.backgroundColor = cssColor(rootPaint.color);
      else if (rootPaint?.gradient) widget.style.backgroundImage = gradientCSS(rootPaint.gradient, size.width, size.height);
      paintMaterial(widget, propReader(root.props).string("backgroundMaterial"), rootPaint, size.width, size.height);
    } else {
      // WidgetKit removes the container background on the Lock Screen and in
      // tinted Home Screen modes; show a neutral wallpaper stand-in.
      widget.style.backgroundColor = renderingMode === "accented" ? "rgba(58, 64, 84, 1)" : "rgba(40, 40, 46, 1)";
      widget.style.colorScheme = "dark";
      if (renderingMode !== "fullColor") report("info", "mode.approximated", `${renderingMode} rendering mode is approximated`);
    }
    const keyframes = doc.createElement("style");
    const swingFrames = axis => Array.from({length: 41}, (_, index) => `${index * 2.5}%{transform:translate${axis}(calc(${Math.sin(index / 40 * 2 * Math.PI)} * var(--sw-swing)))}`).join("");
    keyframes.textContent = `@keyframes sw-clock{from{transform:rotate(var(--sw-start-angle))}to{transform:rotate(calc(var(--sw-start-angle) + 360deg))}}@keyframes sw-swing-X{${swingFrames("X")}}@keyframes sw-swing-Y{${swingFrames("Y")}}`;
    widget.appendChild(keyframes);
    draw(rootNode, widget);
    return { element: widget, size, diagnostics };
  } finally {
    setPlatform(previousPlatform);
    measurer.dispose();
  }
}
