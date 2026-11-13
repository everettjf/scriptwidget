// Android render entry. Runs the shared web renderer (layout, tag builders,
// icons, charts, gauges) inside QuickJS against a recording document, then
// hands the recorded element tree to Kotlin, which paints it on a Canvas.
//
// Only trusted code runs in this context: the input is a canonical element
// tree (data), never package JavaScript.
import { renderWidget } from "../../../../../../Web/preview-engine/src/render/renderer.js";

const SVG_NAMESPACE = "http://www.w3.org/2000/svg";

function createDocument(native) {
  class Style {
    setProperty(name, value) { this[name] = String(value); }
    getPropertyValue(name) { return this[name] ?? ""; }
  }

  class Element {
    constructor(tag, svg) {
      this.tagName = tag;
      this.svg = svg;
      this.style = new Style();
      this.attributes = {};
      this.dataset = {};
      this.children = [];
      this.text = null;
      this.ownerDocument = document;
    }
    appendChild(child) { this.children.push(child); return child; }
    replaceChildren(...children) { this.children = children; this.text = null; }
    remove() {}
    setAttribute(name, value) { this.attributes[name] = String(value); }
    getAttribute(name) { return Object.hasOwn(this.attributes, name) ? this.attributes[name] : null; }
    get textContent() { return this.text ?? ""; }
    set textContent(value) { this.children = []; this.text = String(value); }
    set innerHTML(markup) { this.children = parseMarkup(markup); this.text = null; }
    querySelector(tag) {
      for (const child of this.children) {
        if (child.tagName === tag) return child;
        const found = child.querySelector?.(tag);
        if (found) return found;
      }
      return null;
    }
    set src(value) { this.attributes.src = String(value); }
    get src() { return this.attributes.src ?? ""; }
    set alt(value) { this.attributes.alt = String(value); }
    set title(value) { this.attributes.title = String(value); }
    set className(value) { this.attributes.class = String(value); }
    // <img>: Kotlin reports the decoded size; decode() never loads anything.
    decode() {
      const size = JSON.parse(native("image.size", this.src) ?? "null");
      if (!size) return Promise.reject(new Error("Image could not be decoded"));
      this.naturalWidth = size[0]; this.naturalHeight = size[1];
      return Promise.resolve();
    }
  }

  /// Parses the small SVG fragments the renderer assigns with innerHTML.
  function parseMarkup(markup) {
    const roots = [];
    const stack = [];
    const tagPattern = /<(\/?)([A-Za-z][A-Za-z0-9]*)((?:\s+[A-Za-z_:][-A-Za-z0-9_:.]*\s*=\s*"[^"]*")*)\s*(\/?)>/g;
    const attributePattern = /([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*"([^"]*)"/g;
    let match;
    while ((match = tagPattern.exec(markup)) !== null) {
      const [, closing, name, attributes, selfClosing] = match;
      if (closing) { stack.pop(); continue; }
      const element = new Element(name, true);
      let attribute;
      while ((attribute = attributePattern.exec(attributes)) !== null) {
        if (attribute[1] === "style") {
          for (const declaration of attribute[2].split(";")) {
            const index = declaration.indexOf(":");
            if (index > 0) element.style[declaration.slice(0, index).trim().replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] = declaration.slice(index + 1).trim();
          }
        } else element.attributes[attribute[1]] = attribute[2].replace(/&quot;/g, '"').replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">");
      }
      (stack.length ? stack.at(-1).children : roots).push(element);
      if (!selfClosing) stack.push(element);
    }
    return roots;
  }

  const document = {
    createElement: (tag) => new Element(String(tag).toLowerCase(), false),
    createElementNS: (namespace, tag) => new Element(String(tag), namespace === SVG_NAMESPACE),
    createTextNode: (text) => ({ textNode: String(text) }),
    defaultView: undefined,
    body: null,
  };
  document.body = new Element("body", false);
  return document;
}

/// Text measurement by the same Android text engine that draws the text.
function createMeasurer(native) {
  const cache = new Map();
  const baselines = new Map();
  const describe = (style) => ({ family: style.family, size: style.size, weight: style.weight, leading: style.leading, design: style.design ?? "default" });
  const measure = (text, style, width) => {
    const key = `${style.key}|${width}|${text}`;
    const cached = cache.get(key);
    if (cached) return cached;
    const result = JSON.parse(native("text.measure", JSON.stringify({ ...describe(style), text, width: width === null || width === Infinity ? null : width })));
    if (cache.size > 4000) cache.clear();
    cache.set(key, result);
    return result;
  };
  return {
    measure,
    baseline(style) {
      if (!baselines.has(style.key)) baselines.set(style.key, Number(native("text.baseline", JSON.stringify(describe(style)))));
      return baselines.get(style.key);
    },
    emojiSize: () => null,
    textAdjustments: () => ({ emoji: null, han: null }),
    ellipsisWidth: (style) => measure("…", style, null).width,
    dispose() {},
  };
}

function serialize(node) {
  if (node.textNode !== undefined) return { x: node.textNode };
  const result = { t: node.tagName };
  if (node.svg) result.g = 1;
  const style = {};
  for (const key of Object.keys(node.style)) { const value = node.style[key]; if (value !== "" && value !== undefined && value !== null) style[key] = String(value); }
  if (Object.keys(style).length) result.s = style;
  if (Object.keys(node.attributes).length) result.a = node.attributes;
  if (Object.keys(node.dataset).length) result.d = node.dataset;
  if (node.text !== null) result.x = node.text;
  if (node.children.length) result.c = node.children.map(serialize);
  return result;
}

/// Renders a canonical tree. `nativeCall` is the synchronous Kotlin bridge.
/// Resolves with JSON text: {width, height, root, diagnostics}.
export async function render(nativeCall, requestText) {
  const request = JSON.parse(requestText);
  globalThis.__scriptWidgetFontStack = "inter";
  const document = createDocument(nativeCall);
  const resources = request.resources ?? {};
  const remote = new Set(request.images ?? []);
  const { element, size, diagnostics } = await renderWidget(request.tree, {
    family: request.family ?? "medium",
    size: { width: request.width, height: request.height },
    appearance: request.dark ? "dark" : "light",
    renderingMode: "fullColor",
    lockScreen: false,
    resources,
    document,
    now: typeof request.now === "number" ? request.now : null,
    animations: "firstFrame",
    reduceTransparency: true,
    textMeasurer: createMeasurer(nativeCall),
    // Package images are "res:<path>"; fetched remote images are passed by URL.
    resolveImageURL: (url) => (/^data:image\/(png|jpeg|webp|gif);base64,/.test(url) || remote.has(url) ? url : null),
    // Android draws the first frame of a GIF.
    gifPreparer: async (url) => ({ url, firstFrame: url, info: {} }),
  });
  return JSON.stringify({ width: size.width, height: size.height, root: serialize(element), diagnostics });
}
