var __swRenderBundle = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // core/src/main/js/render/entry.mjs
  var entry_exports = {};
  __export(entry_exports, {
    render: () => render
  });

  // ../Web/preview-engine/src/render/props.js
  var swiftSplit = (value, separator) => value.split(separator).filter((part) => part !== "");
  function swiftDouble(text) {
    if (typeof text !== "string") return null;
    if (/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(text)) return Number(text);
    if (/^[+-]?(inf|infinity)$/i.test(text)) return text.startsWith("-") ? -Infinity : Infinity;
    if (/^[+-]?nan$/i.test(text)) return NaN;
    if (/^[+-]?0[xX][0-9a-fA-F]+$/.test(text)) return (text.startsWith("-") ? -1 : 1) * parseInt(text.replace(/^[+-]?0[xX]/, ""), 16);
    return null;
  }
  function parseRotation3D(value) {
    if (typeof value !== "string") return null;
    const parts = value.split(",");
    if (parts.length !== 4) return null;
    const values = parts.map((part) => swiftDouble(part.trim()));
    if (!values.every((value2) => typeof value2 === "number" && Number.isFinite(value2))) return null;
    const scale = Math.max(...values.slice(1).map((value2) => Math.abs(value2)));
    if (scale === 0) return null;
    return { degree: values[0] % 360, x: values[1] / scale, y: values[2] / scale, z: values[3] / scale };
  }
  var swiftInt = (text) => typeof text === "string" && /^[+-]?\d+$/.test(text) ? Number(text) : null;
  function propReader(props) {
    const map = props ?? {};
    const has = (key) => Object.prototype.hasOwnProperty.call(map, key);
    return {
      has,
      keys: () => Object.keys(map),
      raw: (key) => has(key) ? map[key] : void 0,
      string(key, or) {
        if (has(key) && typeof map[key] === "string") return map[key];
        if (or !== void 0 && has(or) && typeof map[or] === "string") return map[or];
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
      }
    };
  }
  var systemColors = {
    light: {
      black: [0, 0, 0, 1],
      white: [255, 255, 255, 1],
      clear: [0, 0, 0, 0],
      gray: [142, 142, 147, 1],
      red: [255, 56, 60, 1],
      green: [52, 199, 89, 1],
      blue: [0, 136, 255, 1],
      orange: [255, 141, 40, 1],
      yellow: [255, 204, 0, 1],
      pink: [255, 45, 85, 1],
      purple: [203, 48, 224, 1],
      primary: [0, 0, 0, 1],
      secondary: [60, 60, 67, 0.6]
    },
    dark: {
      black: [0, 0, 0, 1],
      white: [255, 255, 255, 1],
      clear: [0, 0, 0, 0],
      gray: [142, 142, 147, 1],
      red: [255, 66, 69, 1],
      green: [48, 209, 88, 1],
      blue: [0, 145, 255, 1],
      orange: [255, 146, 48, 1],
      yellow: [255, 214, 0, 1],
      pink: [255, 55, 95, 1],
      purple: [219, 52, 242, 1],
      primary: [255, 255, 255, 1],
      secondary: [235, 235, 245, 0.6]
    }
  };
  var macSystemColors = {
    light: { ...systemColors.light, primary: [0, 0, 0, 0.847], secondary: [0, 0, 0, 0.498] },
    dark: { ...systemColors.dark, gray: [152, 152, 157, 1], primary: [255, 255, 255, 0.847], secondary: [255, 255, 255, 0.549] }
  };
  var systemBackgrounds = {
    ios: { light: [255, 255, 255, 1], dark: [0, 0, 0, 1] },
    // ShapeStyle.background, which the macOS widget's containerBackground uses.
    macos: { light: [255, 255, 255, 1], dark: [46, 46, 46, 1] }
  };
  var currentPlatform = "ios";
  var platform = () => currentPlatform;
  function setPlatform(name) {
    const previous = currentPlatform;
    currentPlatform = name === "macos" ? "macos" : "ios";
    return previous;
  }
  var palette = () => currentPlatform === "macos" ? macSystemColors : systemColors;
  var systemBackground = (appearance) => systemBackgrounds[currentPlatform][appearance];
  function hexColor(value) {
    const hex = value.replace(/^[^A-Za-z0-9]+|[^A-Za-z0-9]+$/g, "");
    const digits = /^[0-9a-fA-F]*/.exec(hex)[0];
    const scanned = digits === "" ? 0n : BigInt("0x" + digits.slice(0, 16));
    const int = scanned & 0xffffffffffffffffn;
    let a2;
    let r;
    let g;
    let b;
    if (hex.length === 6) {
      a2 = 255n;
      r = int >> 16n;
      g = int >> 8n & 0xffn;
      b = int & 0xffn;
    } else if (hex.length === 8) {
      a2 = int >> 24n;
      r = int >> 16n & 0xffn;
      g = int >> 8n & 0xffn;
      b = int & 0xffn;
    } else {
      a2 = 1n;
      r = 1n;
      g = 1n;
      b = 1n;
    }
    const channel = (x) => Number(x & 0xffffffffn);
    return [channel(r), channel(g), channel(b), Math.min(1, channel(a2) / 255)];
  }
  function builtinColor(name, appearance) {
    return Object.prototype.hasOwnProperty.call(systemColors.light, name) ? palette()[appearance][name] : null;
  }
  function parseColor(value, appearance = "light") {
    const parts = swiftSplit(value, ",");
    const base = (part) => part.startsWith("#") ? hexColor(part) : builtinColor(part, appearance);
    if (parts.length === 1) return base(value.startsWith("#") ? value : value);
    if (parts.length === 2) {
      const color = base(parts[0]);
      if (!color) return null;
      const opacity = swiftDouble(parts[1]);
      return opacity === null ? color : [color[0], color[1], color[2], color[3] * Math.max(0, Math.min(1, opacity))];
    }
    return null;
  }
  var cssColor = ([r, g, b, a2]) => `rgba(${Math.round(r)}, ${Math.round(g)}, ${Math.round(b)}, ${+a2.toFixed(4)})`;
  function parsePoint(value) {
    const named = {
      zero: [0, 0],
      center: [0.5, 0.5],
      leading: [0, 0.5],
      trailing: [1, 0.5],
      top: [0.5, 0],
      bottom: [0.5, 1],
      topLeading: [0, 0],
      topTrailing: [1, 0],
      bottomLeading: [0, 1],
      bottomTrailing: [1, 1]
    };
    const parts = swiftSplit(value, ",");
    if (parts.length === 1) return named[value] ?? [0, 0];
    if (parts.length === 2) return [swiftDouble(parts[0]) ?? 0, swiftDouble(parts[1]) ?? 0];
    return [0, 0];
  }
  function parseGradient(value, appearance = "light") {
    const fallback = { type: "linear", colors: [palette()[appearance].orange, palette()[appearance].red], start: [0, 0.5], end: [1, 0.5] };
    let json;
    try {
      json = JSON.parse(value.slice("gradient:".length));
    } catch {
      return fallback;
    }
    if (!json || typeof json !== "object") return fallback;
    const stringValue = (item) => typeof item === "string" ? item : typeof item === "number" || typeof item === "boolean" ? String(item) : "";
    const doubleValue = (item) => typeof item === "number" ? item : typeof item === "string" ? Number.isFinite(Number(item)) && item.trim() !== "" ? Number(item) : 0 : item === true ? 1 : 0;
    const colors = (Array.isArray(json.colors) ? json.colors : []).map((item) => parseColor(stringValue(item), appearance) ?? [0, 0, 0, 0]);
    const type = stringValue(json.type);
    if (type === "linear") return { type, colors, start: parsePoint(stringValue(json.startPoint)), end: parsePoint(stringValue(json.endPoint)) };
    if (type === "radial") return { type, colors, center: parsePoint(stringValue(json.center)), startRadius: doubleValue(json.startRadius), endRadius: doubleValue(json.endRadius) };
    if (type === "angular") return { type, colors, center: parsePoint(stringValue(json.center)) };
    return fallback;
  }
  function parsePaint(value, appearance) {
    if (typeof value !== "string") return null;
    if (value.startsWith("gradient:")) return { gradient: parseGradient(value, appearance) };
    const color = parseColor(value, appearance);
    return color ? { color } : null;
  }
  function gradientCSS(gradient, width, height) {
    const stops = (positions) => gradient.colors.map((color, index) => `${cssColor(color)} ${positions(index)}`).join(", ");
    const n = Math.max(1, gradient.colors.length - 1);
    if (gradient.colors.length === 0) return "transparent";
    if (gradient.colors.length === 1) return cssColor(gradient.colors[0]);
    if (gradient.type === "radial") {
      const [cx, cy] = gradient.center;
      return `radial-gradient(circle farthest-corner at ${cx * width}px ${cy * height}px, ${stops((i) => `${gradient.startRadius + i / n * (gradient.endRadius - gradient.startRadius)}px`)})`;
    }
    if (gradient.type === "angular") {
      const [cx, cy] = gradient.center;
      return `conic-gradient(from 90deg at ${cx * width}px ${cy * height}px, ${stops((i) => `${i / n * 360}deg`)})`;
    }
    const sx = gradient.start[0] * width;
    const sy = gradient.start[1] * height;
    const ex = gradient.end[0] * width;
    const ey = gradient.end[1] * height;
    const dx = ex - sx;
    const dy = ey - sy;
    if (dx === 0 && dy === 0) return cssColor(gradient.colors.at(-1));
    const angle = Math.atan2(dx, -dy);
    const ux = Math.sin(angle);
    const uy = -Math.cos(angle);
    const length = Math.abs(width * Math.sin(angle)) + Math.abs(height * Math.cos(angle));
    const along = (x, y) => (x - width / 2) * ux + (y - height / 2) * uy + length / 2;
    const t0 = along(sx, sy);
    const t1 = along(ex, ey);
    return `linear-gradient(${angle * 180 / Math.PI}deg, ${stops((i) => `${t0 + i / n * (t1 - t0)}px`)})`;
  }
  var alignments = {
    center: ["center", "center"],
    leading: ["start", "center"],
    trailing: ["end", "center"],
    top: ["center", "start"],
    bottom: ["center", "end"],
    topLeading: ["start", "start"],
    topTrailing: ["end", "start"],
    bottomLeading: ["start", "end"],
    bottomTrailing: ["end", "end"]
  };
  function parseFrame(reader) {
    const raw = reader.raw("frame");
    let value = reader.string("frame");
    if (value === null && typeof raw === "number") value = Number.isInteger(raw) ? `${raw}.0` : String(raw);
    const result = { mode: "none", alignment: "center", width: 0, height: 0 };
    if (value === null) return result;
    const parts = swiftSplit(value, ",");
    const alignmentName = (name) => alignments[name] ? name : "center";
    if (parts.length === 1) {
      if (value === "max") result.mode = "max";
      else {
        const side = swiftDouble(value);
        if (side !== null && Number.isFinite(side) && side >= 0) Object.assign(result, { mode: "size", width: side, height: side });
      }
    } else if (parts.length === 2) {
      const [a2, b] = parts;
      const w = swiftDouble(a2);
      const h = swiftDouble(b);
      if (w !== null && h !== null) Object.assign(result, { mode: "size", width: w, height: h });
      else {
        if (a2 === "max") {
          if (h !== null) Object.assign(result, { mode: "height", height: h });
          else Object.assign(result, { mode: "max", alignment: alignmentName(b) });
        }
        if (b === "max" && w !== null) Object.assign(result, { mode: "width", width: w });
      }
    } else if (parts.length === 3) {
      const [a2, b, c] = parts;
      const w = swiftDouble(a2);
      const h = swiftDouble(b);
      if (w !== null && h !== null) Object.assign(result, { mode: "size", width: w, height: h, alignment: alignmentName(c) });
      if (a2 === "max" && h !== null) Object.assign(result, { mode: "height", height: h, alignment: alignmentName(c) });
      if (b === "max" && w !== null) Object.assign(result, { mode: "width", width: w, alignment: alignmentName(c) });
    }
    return result;
  }
  function parsePadding(reader) {
    const value = reader.string("padding");
    if (value === null) return null;
    const parts = swiftSplit(value, ",");
    const number = (text) => swiftDouble(text) ?? 0;
    if (parts.length === 1) {
      const all = number(value);
      return [all, all, all, all];
    }
    if (parts.length === 2) {
      const amount = number(parts[1]);
      const edges = {
        top: [1, 0, 0, 0],
        leading: [0, 0, 0, 1],
        bottom: [0, 0, 1, 0],
        trailing: [0, 1, 0, 0],
        horizontal: [0, 1, 0, 1],
        vertical: [1, 0, 1, 0],
        all: [1, 1, 1, 1]
      }[parts[0]] ?? [1, 1, 1, 1];
      return edges.map((on) => on * amount);
    }
    if (parts.length === 4) return parts.map(number);
    return null;
  }
  var textStyles = {
    largeTitle: [34, 41, 400],
    title: [28, 34, 400],
    title2: [22, 28, 400],
    title3: [20, 25, 400],
    headline: [17, 22, 600],
    body: [17, 22, 400],
    callout: [16, 21, 400],
    subheadline: [15, 20, 400],
    footnote: [13, 18, 400],
    caption: [12, 16, 400],
    caption2: [11, 13, 400]
  };
  var macTextStyles = {
    largeTitle: [26, 31, 32, 400, 1.5],
    title: [22, 26, 26, 400, 0.5],
    title2: [17, 20.5, 22, 400, 2],
    title3: [15, 19, 20, 400, 2.5],
    headline: [13, 16, 16, 700, 1],
    body: [13, 16, 16, 400, 1],
    callout: [12, 15, 15, 400, 1],
    subheadline: [11, 14, 14, 400, 1.5],
    footnote: [10, 13, 13, 400, 1.5],
    caption: [10, 13, 13, 400, 1.5],
    caption2: [10, 13, 13, 400, 1.5]
  };
  function styleFont(name) {
    if (currentPlatform === "macos") {
      const [size2, natural, lineHeight3, weight2, gap] = macTextStyles[name];
      return { size: size2, natural, lineHeight: lineHeight3, weight: weight2, gap, design: "default", textStyle: name };
    }
    const [size, lineHeight2, weight] = textStyles[name];
    return { size, lineHeight: lineHeight2, weight, design: "default", textStyle: name };
  }
  var weights = { ultraLight: 100, thin: 200, light: 300, regular: 400, medium: 500, semibold: 600, bold: 700, heavy: 800, black: 900 };
  var designs = { monospaced: "monospaced", rounded: "rounded", serif: "serif", default: "default" };
  function parseFont(value) {
    if (typeof value !== "string") return null;
    const fromName = (name, designName) => {
      if (textStyles[name]) return styleFont(name);
      const size = swiftDouble(name);
      if (size === null) return null;
      return { size, lineHeight: null, weight: 400, design: designName && designs[designName] || "default" };
    };
    const parts = swiftSplit(value, ",");
    let font = null;
    let weight = null;
    if (parts.length === 1) font = fromName(value, null);
    else if (parts.length === 2) {
      font = fromName(parts[0], null);
      weight = weights[parts[1]] ?? null;
    } else if (parts.length === 3) {
      if (parts[0] === "custom") font = { size: swiftDouble(parts[2]) ?? 10, lineHeight: null, weight: 400, design: "default", family: parts[1] };
      else {
        font = fromName(parts[0], parts[2]);
        weight = weights[parts[1]] ?? null;
      }
    }
    if (font && weight !== null) font.weight = weight;
    return font;
  }
  var defaultFont = () => styleFont("body");
  function elementFont(reader, fallback = defaultFont()) {
    const font = { ...parseFont(reader.string("font")) ?? fallback };
    const weight = weights[reader.string("fontWeight") ?? reader.string("weight") ?? ""];
    if (weight !== void 0) font.weight = weight;
    const design = designs[reader.string("fontDesign") ?? ""];
    if (design !== void 0 && !font.family) font.design = design;
    return font;
  }
  var fallbackOnly = () => globalThis.__scriptWidgetFontStack === "fallback";
  var interOnly = () => globalThis.__scriptWidgetFontStack === "inter";
  function fontFamily(font) {
    if (interOnly() && font.design !== "monospaced" && font.design !== "serif") return '"ScriptWidget Inter", Arial, sans-serif';
    if (fallbackOnly()) return font.design === "monospaced" ? 'Consolas, "Courier New", monospace' : '"Segoe UI", Roboto, Arial, Helvetica, sans-serif';
    if (font.family) return `"${font.family.replace(/"/g, "")}", -apple-system, "ScriptWidget Inter", system-ui, sans-serif`;
    switch (font.design) {
      case "rounded":
        return `"SF Pro Rounded", ui-rounded, -apple-system, "ScriptWidget Inter", system-ui, sans-serif`;
      case "monospaced":
        return `ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace`;
      case "serif":
        return `"New York", ui-serif, Georgia, "Times New Roman", serif`;
      default:
        return `-apple-system, BlinkMacSystemFont, "SF Pro Text", "ScriptWidget Inter", system-ui, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif`;
    }
  }

  // ../Web/preview-engine/src/render/gif.js
  var gifLimits = Object.freeze({ inputBytes: 8 * 1024 * 1024, canvasPixels: 1048576, frames: 60, decodedBytes: 4 * 1024 * 1024, edge: 512 });
  function inspectGif(bytes) {
    if (!(bytes instanceof Uint8Array) || bytes.length > gifLimits.inputBytes || bytes.length < 14) throw new Error("GIF input limit or invalid header");
    const header = String.fromCharCode(...bytes.subarray(0, 6));
    if (header !== "GIF87a" && header !== "GIF89a") throw new Error("Invalid GIF signature");
    const word = (offset2) => bytes[offset2] | bytes[offset2 + 1] << 8;
    const width = word(6), height = word(8);
    if (!width || !height || width * height > gifLimits.canvasPixels) throw new Error("GIF canvas limit");
    let offset = 13 + (bytes[10] & 128 ? 3 * 2 ** ((bytes[10] & 7) + 1) : 0), count = 0, delay = 0.1, complete = false;
    const delays = [];
    const skipBlocks = () => {
      while (offset < bytes.length) {
        const length = bytes[offset++];
        if (!length) return;
        offset += length;
      }
      throw new Error("Truncated GIF block");
    };
    while (offset < bytes.length) {
      const block = bytes[offset++];
      if (block === 59) {
        complete = true;
        break;
      }
      if (block === 33) {
        const label = bytes[offset++];
        if (label === 249) {
          if (offset + 6 > bytes.length || bytes[offset] !== 4 || bytes[offset + 5] !== 0) throw new Error("Invalid GIF delay block");
          const raw = word(offset + 2) / 100;
          delay = raw < 0.011 ? 0.1 : raw;
          offset += 6;
        } else skipBlocks();
      } else if (block === 44) {
        if (offset + 9 >= bytes.length) throw new Error("Truncated GIF frame");
        const frameWidth = word(offset + 4), frameHeight = word(offset + 6), flags = bytes[offset + 8];
        if (!frameWidth || !frameHeight || frameWidth * frameHeight > gifLimits.canvasPixels) throw new Error("GIF frame canvas limit");
        offset += 9 + (flags & 128 ? 3 * 2 ** ((flags & 7) + 1) : 0);
        if (offset >= bytes.length || bytes[offset] < 2 || bytes[offset] > 8) throw new Error("Invalid GIF LZW header");
        offset++;
        skipBlocks();
        count++;
        if (delays.length < gifLimits.frames) delays.push(delay);
        delay = 0.1;
      } else throw new Error("Invalid GIF block");
    }
    if (!complete || !count || offset > bytes.length) throw new Error("Incomplete GIF");
    return { width, height, count, delays, frameLimit: count > gifLimits.frames, estimatedDecodedBytes: width * height * count * 4 };
  }
  async function readGifBytes(url, fetcher = globalThis.fetch) {
    if (typeof url === "string" && /^data:/i.test(url)) {
      const prefix = "data:image/gif;base64,";
      if (!url.startsWith(prefix)) throw new Error("Invalid GIF data URL");
      const encodedLength = url.length - prefix.length;
      if (encodedLength > Math.ceil(gifLimits.inputBytes / 3) * 4 || encodedLength % 4 !== 0) throw new Error("GIF input limit");
      const encoded = url.slice(prefix.length);
      if (!/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) throw new Error("Invalid GIF base64");
      const padding = encoded.endsWith("==") ? 2 : encoded.endsWith("=") ? 1 : 0;
      if (encodedLength / 4 * 3 - padding > gifLimits.inputBytes) throw new Error("GIF input limit");
      return Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));
    }
    const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 5e3);
    let reader;
    try {
      const response = await fetcher(url, { signal: controller.signal });
      if (!response.ok || Number(response.headers.get("content-length")) > gifLimits.inputBytes || !response.body?.getReader) throw new Error("GIF response limit");
      reader = response.body.getReader();
      const chunks = [];
      let length = 0;
      while (true) {
        const item = await reader.read();
        if (item.done) break;
        length += item.value.length;
        if (length > gifLimits.inputBytes) throw new Error("GIF input limit");
        chunks.push(item.value);
      }
      const bytes = new Uint8Array(length);
      let offset = 0;
      for (const chunk of chunks) {
        bytes.set(chunk, offset);
        offset += chunk.length;
      }
      return bytes;
    } finally {
      clearTimeout(timeout);
      if (reader) {
        try {
          await reader.cancel();
        } catch {
        }
      }
      controller.abort();
    }
  }
  async function prepareGif(url, { document: doc, firstFrame = false, needImage = false } = {}) {
    const bytes = await readGifBytes(url), info = inspectGif(bytes), blob = new Blob([bytes], { type: "image/gif" });
    const memoryFallback = info.estimatedDecodedBytes > gifLimits.decodedBytes;
    const freeze = firstFrame || info.frameLimit || memoryFallback;
    let decoder, primary = null, still = null;
    const edge = firstFrame || info.frameLimit || memoryFallback ? gifLimits.edge : Math.min(gifLimits.edge, Math.floor(Math.sqrt(gifLimits.decodedBytes / (4 * info.count)) / 16) * 16);
    try {
      const frame = async (index) => {
        let bitmap;
        try {
          if (typeof globalThis.ImageDecoder === "function") {
            decoder ??= new ImageDecoder({ data: bytes, type: "image/gif" });
            await decoder.tracks.ready;
            bitmap = (await decoder.decode({ frameIndex: index })).image;
          } else bitmap = await createImageBitmap(blob);
          const width = bitmap.displayWidth ?? bitmap.width, height = bitmap.displayHeight ?? bitmap.height;
          if (!width || !height || width * height > gifLimits.canvasPixels) throw new Error("Decoded GIF canvas limit");
          const canvas = doc.createElement("canvas"), ratio = Math.min(1, edge / Math.max(width, height));
          canvas.width = Math.max(1, Math.floor(width * ratio));
          canvas.height = Math.max(1, Math.floor(height * ratio));
          const context = canvas.getContext("2d");
          if (!context) throw new Error("GIF canvas unavailable");
          context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
          return canvas.toDataURL("image/png");
        } finally {
          bitmap?.close?.();
        }
      };
      if (firstFrame || info.frameLimit || memoryFallback || needImage) still = await frame(0);
      if (freeze) {
        primary = still ?? await frame(0);
      } else primary = await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onerror = () => reject(new Error("GIF conversion failed"));
        reader.onload = () => resolve(reader.result);
        reader.readAsDataURL(blob);
      });
      return { url: primary, firstFrame: still, info, memoryFallback };
    } finally {
      decoder?.close();
    }
  }

  // ../Web/preview-engine/src/render/animation.js
  var clockPeriods = Object.freeze({ clockSecond: 60, clockMinute: 3600, clockMiniute: 3600, clockHour: 43200 });
  var clockPeriod = (value) => Number.isFinite(value) ? Math.abs(value) < 0.25 ? value < 0 ? -0.25 : 0.25 : value : 10;
  var swingDuration = (value) => Number.isFinite(value) && value > 0 ? Math.min(86400, Math.max(0.1, value)) : 1;
  var swingDistance = (value) => Number.isFinite(value) ? Math.min(1e4, Math.max(-1e4, value)) : 10;
  function swingPhase(elapsed, duration, distance) {
    if (!Number.isFinite(elapsed)) return 0;
    const period = swingDuration(duration);
    return Math.sin(elapsed % (2 * period) / period * Math.PI) * swingDistance(distance);
  }
  function clockPhase({ type, interval = 10, date, timezone = "current" }) {
    if (!Number.isFinite(date) || date < -621355968e5 || date > 253402300799e3) return 0;
    const moment = new Date(date), options = { year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric", hourCycle: "h23", calendar: "gregory", numberingSystem: "latn" };
    let parts;
    try {
      parts = new Intl.DateTimeFormat("en-US", timezone === "current" ? options : { ...options, timeZone: timezone }).formatToParts(moment);
    } catch {
      parts = new Intl.DateTimeFormat("en-US", options).formatToParts(moment);
    }
    const get = (key) => Number(parts.find((part) => part.type === key)?.value ?? 0);
    if (type === "clock") {
      const local = /* @__PURE__ */ new Date(0);
      local.setUTCFullYear(get("year"), get("month") - 1, get("day"));
      local.setUTCHours(get("hour"), get("minute"), get("second"), moment.getUTCMilliseconds());
      return (local.getTime() / 1e3 - 978307200) / clockPeriod(interval) % 2 * 180;
    }
    const cycle = clockPeriods[type];
    if (!cycle) return 0;
    const seconds = get("hour") * 3600 + get("minute") * 60 + get("second") + moment.getUTCMilliseconds() / 1e3;
    return seconds % cycle / cycle * 360;
  }

  // ../Web/preview-engine/src/render/coverage.js
  var s = (note = "") => ({ state: "supported", note });
  var fontProps = () => ({ fontWeight: { state: "supported", note: "Overrides the weight in font" }, weight: { state: "supported", note: "Older alias of fontWeight" }, fontDesign: { state: "supported", note: "default, rounded, serif, monospaced" } });
  var a = (note) => ({ state: "approximated", note });
  var generalProps = Object.freeze({
    padding: s('String values only, as on iPhone: "10", "horizontal,8", "t,r,b,l"'),
    frame: s('Includes the native quirk: "max,20" sets only the height'),
    background: s("Color or $gradient; on the root element it becomes the widget container background"),
    backgroundMaterial: a("Public SwiftUI material approximated with CSS backdrop blur; Reduce Transparency uses an opaque fallback and accented/vibrant modes omit local material. Not Home Screen wallpaper blur or system Liquid Glass."),
    corner: s(),
    clip: s(),
    opacity: s(),
    animation: a("Public scheduled native clock/swing effects use CSS approximations here. Signed custom half-turn periods and fixed poses match native. Reduce Motion freezes the preview; WidgetKit cadence is system-controlled."),
    rotation: s(),
    rotation3d: a("CSS perspective differs from SwiftUI's"),
    shadow: a("Blur radius mapped to CSS drop-shadow; edges may differ slightly"),
    widgetAccentable: a("Only affects accented rendering mode, which the web preview does not emulate yet"),
    linkurl: s("Tap targets are not interactive in the preview")
  });
  var coverage = Object.freeze({
    tags: {
      vstack: { state: "supported", props: { alignment: s(), spacing: s("Default spacing measured on iOS 27") } },
      hstack: { state: "supported", props: { alignment: s(), spacing: s() } },
      zstack: { state: "supported", props: {} },
      hgrid: { state: "approximated", note: "Lazy grid tracks; cells are centered", props: { columns: s("fixed, flexible, adaptive"), alignment: a("Cells are centered"), spacing: s() } },
      vgrid: { state: "approximated", note: "Lazy grid tracks; cells are centered", props: { columns: s("fixed, flexible, adaptive"), alignment: a("Cells are centered"), spacing: s() } },
      text: { state: "supported", props: { ...fontProps(), font: s("SF metrics on Apple systems; fallback fonts elsewhere"), color: s(), alignment: s() } },
      date: { state: "approximated", note: "Real clock like iPhone; English formats", props: { ...fontProps(), date: s("now, tomorrow, yesterday, start of today, +Nh, -Nd, or milliseconds"), style: a("English formats; timers do not tick"), font: s(), color: s(), alignment: s() } },
      image: { state: "approximated", note: "Package images render; SF Symbols use look-alike icons; remote URLs show placeholders", props: {
        systemName: a("Look-alike Lucide icon"),
        name: s("Needs the package image file"),
        id: s("Alias of name"),
        url: a("data: PNG/JPEG only; remote URLs are not loaded"),
        src: a("Alias of url"),
        ratio: s("With mode fit or fill"),
        mode: s(),
        font: s(),
        ...fontProps(),
        accentedRenderingMode: a("Accented mode is not emulated")
      } },
      gif: { state: "approximated", note: "Bounded browser GIF playback; Reduce Motion/Mac and resource limits use a static frame. Native timing differs", props: { file: s("Resolved like ScriptWidgetPackage.getGifFile"), font: s(), ...fontProps() } },
      spacer: { state: "supported", props: {} },
      rect: { state: "supported", props: { corner: s(), trim: a("Trim applies to strokes only"), stroke: s(), color: s() } },
      capsule: { state: "supported", props: { trim: a("Trim applies to strokes only"), stroke: s(), color: s() } },
      ellipse: { state: "supported", props: { trim: a("Trim applies to strokes only"), stroke: s(), color: s() } },
      circle: { state: "supported", props: { trim: a("Trim applies to strokes only"), stroke: s(), color: s() } },
      gauge: { state: "approximated", note: "Original gauge drawn like MineGaugeView; system gauge styles approximated", props: {
        ...Object.fromEntries(["value", "angle", "label", "needleColor", "sections", "thickness", "title", "labelFont", "labelColor", "titleColor"].map((key) => [key, s()])),
        ...Object.fromEntries(["current", "max", "min", "style", "text", "type"].map((key) => [key, a("System gauge styles are approximated")])),
        titleFont: { state: "supported", note: "Not read natively; the title uses labelFont" }
      } },
      chart: { state: "approximated", note: "SVG approximation of Swift Charts marks, axes, and legend", props: Object.fromEntries(["category", "hideLegend", "hideXAxis", "hideYAxis", "data", "type", "color"].map((key) => [key, a("Swift Charts styling differs")])) },
      link: { state: "approximated", note: "Children laid out vertically; not interactive", props: { url: s() } },
      divider: { state: "supported", props: { thickness: s(), axis: s(), color: s() } },
      line: { state: "supported", props: { thickness: s(), length: s(), axis: s(), color: s() } },
      roundedrect: { state: "supported", props: { radius: s(), color: s() } },
      icon: { state: "approximated", note: "SF Symbols are drawn with look-alike Lucide icons (ISC); unmapped names show a placeholder", props: { ...fontProps(), systemName: a("Look-alike Lucide icon"), size: s(), color: s(), font: s() } },
      label: { state: "approximated", note: "Icon is a look-alike Lucide icon", props: { ...fontProps(), title: s(), systemName: a("Look-alike Lucide icon"), color: s(), font: s() } },
      progress: { state: "supported", props: { value: s(), total: s(), label: s(), style: s(), color: s(), trackColor: s(), thickness: s(), frame: s("Circular size") } },
      ring: { state: "supported", props: { value: s(), thickness: s(), color: s(), trackColor: s() } },
      badge: { state: "supported", props: { text: s(), radius: s(), background: s(), color: s() } },
      chip: { state: "supported", props: { text: s(), radius: s(), background: s(), borderColor: s(), color: s() } },
      stat: { state: "supported", props: { title: s(), value: s(), subtitle: s(), color: s(), mutedColor: s() } },
      button: { state: "approximated", note: "Label only; taps run on iPhone", props: { action: s(), actionID: s(), onClick: s() } },
      toggle: { state: "approximated", note: "Static switch on iOS, static checkbox on macOS", props: { on: s(), actionID: s(), onClick: s(), stateKey: s() } },
      Fragment: { state: "supported", props: {} }
    }
  });
  var withoutGeneral = /* @__PURE__ */ new Set(["spacer", "Fragment"]);
  function ignoredProp(tag, key) {
    const entry = coverage.tags[tag];
    if (!entry) return null;
    if (Object.prototype.hasOwnProperty.call(entry.props, key)) return null;
    if (tag === "spacer") return key === "frame" ? null : "is ignored by the native runtime (Spacer reads only frame)";
    if (!withoutGeneral.has(tag) && Object.prototype.hasOwnProperty.call(generalProps, key)) return null;
    if (key === "key" || key === "children") return null;
    return "is ignored by the native runtime";
  }

  // ../Web/preview-engine/src/render/profiles.js
  var accessories = { accessoryCircular: [72, 72], accessoryRectangular: [170, 72], accessoryInline: [250, 30] };
  var deviceProfiles = Object.freeze({
    "iphone-430": { label: "iPhone Pro Max (430 pt)", small: [170, 170], medium: [364, 170], large: [364, 382], ...accessories },
    "iphone-393": { label: "iPhone / iPhone Pro (393 pt)", small: [158, 158], medium: [338, 158], large: [338, 354], ...accessories },
    "iphone-375": { label: "iPhone SE (375 pt)", small: [148, 148], medium: [321, 148], large: [321, 324], ...accessories },
    "ipad-1024": { label: "iPad Pro 12.9-inch", small: [170, 170], medium: [379, 170], large: [379, 379], extraLarge: [800, 379], extraLargePortrait: [379, 800] },
    // macOS desktop widgets (AIWidgetSize.previewSize), rendered with macOS
    // SwiftUI metrics; compared against Tools/ScriptWidgetPreview.
    macos: { label: "Mac", platform: "macos", small: [170, 170], medium: [329, 170], large: [329, 345], extraLarge: [639, 345] }
  });
  var widgetFamilies = Object.freeze(["small", "medium", "large", "extraLarge", "extraLargePortrait", "accessoryCircular", "accessoryRectangular", "accessoryInline"]);
  function widgetSize(profile, family) {
    const sizes = deviceProfiles[profile] ?? deviceProfiles["iphone-393"];
    const [width, height] = sizes[family] ?? sizes.medium;
    return { width, height };
  }

  // ../Web/preview-engine/src/render/symbolMetrics.generated.js
  var symbolMetrics = Object.freeze({
    "airplane": [1.235, 1.165],
    "airplane.departure": [1.505, 1.04],
    "alarm": [1.105, 1.185],
    "alarm.fill": [1.105, 1.185],
    "alarm.waves.left.and.right": [1.925, 1.185],
    "alarm.waves.left.and.right.fill": [1.925, 1.185],
    "ant": [1.065, 1.34],
    "ant.fill": [1.065, 1.34],
    "antenna.radiowaves.left.and.right": [1.21, 1.085],
    "app.badge": [1.155, 1.23],
    "app.badge.fill": [1.15, 1.225],
    "applewatch": [1.005, 1.215],
    "aqi.medium": [1.385, 1.36],
    "archivebox": [1.23, 1.07],
    "archivebox.fill": [1.23, 1.07],
    "arrow.clockwise": [1.035, 1.22],
    "arrow.counterclockwise": [1.035, 1.22],
    "arrow.down": [0.995, 1.095],
    "arrow.down.right": [0.975, 0.9],
    "arrow.left": [1.16, 0.915],
    "arrow.right": [1.16, 0.915],
    "arrow.triangle.2.circlepath": [1.17, 1.17],
    "arrow.triangle.branch": [1.155, 1.085],
    "arrow.up": [0.995, 1.095],
    "arrow.up.arrow.down": [1.405, 1.125],
    "arrow.up.right": [0.975, 0.895],
    "backward": [1.475, 0.92],
    "backward.end": [1, 0.92],
    "backward.end.fill": [1.155, 0.92],
    "backward.fill": [1.475, 0.92],
    "bag": [1.12, 1.155],
    "bag.fill": [1.12, 1.155],
    "banknote": [1.54, 0.98],
    "banknote.fill": [1.54, 0.98],
    "battery.0": [1.7, 0.835],
    "battery.100": [1.7, 0.835],
    "battery.100.bolt": [1.7, 1.06],
    "battery.25": [1.7, 0.835],
    "battery.50": [1.7, 0.835],
    "battery.75": [1.7, 0.835],
    "bed.double": [1.49, 0.995],
    "bed.double.circle": [1.17, 1.17],
    "bed.double.circle.fill": [1.17, 1.17],
    "bed.double.fill": [1.49, 0.995],
    "bell": [1.135, 1.18],
    "bell.badge": [1.13, 1.25],
    "bell.badge.fill": [1.13, 1.27],
    "bell.fill": [1.135, 1.2],
    "bell.slash": [1.13, 1.255],
    "bell.slash.fill": [1.13, 1.255],
    "bicycle": [1.835, 1.155],
    "bird": [1.4, 1.49],
    "bird.fill": [1.4, 1.49],
    "birthday.cake": [1.375, 1.285],
    "birthday.cake.fill": [1.375, 1.285],
    "bitcoinsign.circle.fill": [1.17, 1.17],
    "bolt": [0.96, 1.305],
    "bolt.car": [1.41, 1.08],
    "bolt.car.fill": [1.41, 1.08],
    "bolt.fill": [0.96, 1.305],
    "bolt.heart": [1.22, 1.07],
    "bolt.heart.fill": [1.22, 1.07],
    "bonjour": [1.27, 1.28],
    "book": [1.335, 1.08],
    "book.closed": [1.075, 1.22],
    "book.closed.fill": [1.075, 1.22],
    "book.fill": [1.375, 1.07],
    "bookmark": [1.02, 1.22],
    "bookmark.fill": [1.02, 1.22],
    "books.vertical": [1.46, 1.265],
    "books.vertical.fill": [1.42, 1.26],
    "brain": [1.455, 1.255],
    "brain.fill": [1.455, 1.255],
    "briefcase": [1.385, 1.12],
    "briefcase.fill": [1.385, 1.12],
    "bubble.left": [1.33, 1.18],
    "bubble.left.and.bubble.right": [1.655, 1.29],
    "bubble.left.and.bubble.right.fill": [1.655, 1.355],
    "bubble.left.fill": [1.33, 1.185],
    "building.2": [1.2, 1.315],
    "building.2.fill": [1.205, 1.45],
    "building.columns": [1.34, 1.215],
    "building.columns.fill": [1.34, 1.215],
    "bus": [1.34, 1.31],
    "bus.fill": [1.32, 1.3],
    "calendar": [1.225, 1.07],
    "calendar.badge.checkmark": [1.225, 1.23],
    "calendar.badge.clock": [1.225, 1.23],
    "calendar.badge.exclamationmark": [1.225, 1.23],
    "calendar.badge.plus": [1.225, 1.23],
    "calendar.circle": [1.17, 1.17],
    "calendar.circle.fill": [1.17, 1.17],
    "calendar.day.timeline.left": [1.43, 1.075],
    "camera": [1.45, 1.105],
    "camera.fill": [1.45, 1.105],
    "camera.macro": [1.305, 1.23],
    "car": [1.41, 1.08],
    "car.fill": [1.41, 1.08],
    "carrot": [1.35, 1.34],
    "carrot.fill": [1.35, 1.34],
    "cart": [1.355, 1.13],
    "cart.badge.plus": [1.355, 1.275],
    "cart.badge.plus.fill": [1.355, 1.285],
    "cart.fill": [1.355, 1.13],
    "chart.bar": [1.495, 1.09],
    "chart.bar.fill": [1.48, 1.085],
    "chart.line.uptrend.xyaxis": [1.3, 1.075],
    "chart.pie": [1.17, 1.17],
    "chart.pie.fill": [1.17, 1.165],
    "chart.xyaxis.line": [1.3, 1.075],
    "checklist": [1.345, 1.16],
    "checkmark": [1.095, 1.005],
    "checkmark.circle": [1.17, 1.17],
    "checkmark.circle.fill": [1.17, 1.17],
    "checkmark.seal": [1.28, 1.315],
    "checkmark.seal.fill": [1.285, 1.315],
    "checkmark.square": [1.15, 1.07],
    "checkmark.square.fill": [1.15, 1.07],
    "chevron.down": [1.1, 0.65],
    "chevron.left": [0.725, 1.02],
    "chevron.left.forwardslash.chevron.right": [1.62, 1.105],
    "chevron.right": [0.725, 1.02],
    "chevron.up": [1.1, 0.65],
    "circle": [1.17, 1.17],
    "circle.fill": [1.17, 1.17],
    "circle.grid.2x2": [1.18, 1.1],
    "circle.grid.2x2.fill": [1.18, 1.1],
    "circle.grid.3x3.fill": [1.255, 1.13],
    "clock": [1.17, 1.17],
    "clock.arrow.circlepath": [1.17, 1.17],
    "clock.badge.fill": [1.17, 1.245],
    "clock.fill": [1.17, 1.17],
    "cloud": [1.315, 0.945],
    "cloud.bolt": [1.235, 1.345],
    "cloud.bolt.fill": [1.235, 1.345],
    "cloud.bolt.rain.fill": [1.235, 1.345],
    "cloud.drizzle": [1.235, 1.295],
    "cloud.drizzle.fill": [1.235, 1.295],
    "cloud.fill": [1.315, 0.945],
    "cloud.fog": [1.235, 1.25],
    "cloud.fog.fill": [1.235, 1.25],
    "cloud.moon": [1.32, 1.025],
    "cloud.moon.fill": [1.325, 1.06],
    "cloud.rain": [1.235, 1.3],
    "cloud.rain.fill": [1.235, 1.3],
    "cloud.snow": [1.235, 1.34],
    "cloud.snow.fill": [1.235, 1.34],
    "cloud.sun": [1.42, 1.185],
    "cloud.sun.fill": [1.425, 1.215],
    "cloud.sun.rain": [1.42, 1.545],
    "cloud.sun.rain.fill": [1.425, 1.545],
    "cpu": [1.235, 1.155],
    "cpu.fill": [1.235, 1.155],
    "creditcard": [1.4, 1.005],
    "creditcard.fill": [1.4, 1.005],
    "cross": [1.3, 1.22],
    "cross.fill": [1.265, 1.185],
    "crown": [1.505, 1.125],
    "crown.fill": [1.505, 1.125],
    "cup.and.saucer": [1.52, 1.12],
    "cup.and.saucer.fill": [1.52, 1.12],
    "desktopcomputer": [1.415, 1.155],
    "dice": [1.285, 1.195],
    "dice.fill": [1.285, 1.26],
    "doc": [1.075, 1.22],
    "doc.fill": [1.075, 1.22],
    "doc.text": [1.075, 1.22],
    "doc.text.fill": [1.075, 1.22],
    "dollarsign.circle": [1.17, 1.17],
    "dollarsign.circle.fill": [1.17, 1.17],
    "dot.radiowaves.left.and.right": [1.445, 1.06],
    "drop": [0.85, 1.16],
    "drop.degreesign": [1.01, 1.28],
    "drop.degreesign.fill": [1.01, 1.28],
    "drop.fill": [0.85, 1.16],
    "dumbbell": [1.485, 0.895],
    "dumbbell.fill": [1.485, 0.895],
    "ellipsis": [1.085, 0.36],
    "ellipsis.circle": [1.17, 1.17],
    "ellipsis.circle.fill": [1.17, 1.17],
    "envelope": [1.43, 1.015],
    "envelope.fill": [1.43, 1.015],
    "envelope.open": [1.43, 1.305],
    "envelope.open.fill": [1.43, 1.305],
    "exclamationmark.circle": [1.17, 1.17],
    "exclamationmark.circle.fill": [1.17, 1.17],
    "exclamationmark.triangle": [1.225, 1.1],
    "exclamationmark.triangle.fill": [1.225, 1.1],
    "eye": [1.535, 1.01],
    "eye.fill": [1.525, 1],
    "eye.slash": [1.535, 1.22],
    "eye.slash.fill": [1.525, 1.195],
    "eyedropper": [1.245, 1.21],
    "face.smiling": [1.17, 1.17],
    "face.smiling.fill": [1.17, 1.17],
    "faceid": [1.21, 1.13],
    "ferry": [1.29, 1.385],
    "ferry.fill": [1.29, 1.375],
    "figure.mind.and.body": [1.29, 1.075],
    "figure.run": [1.065, 1.25],
    "figure.walk": [0.94, 1.32],
    "figure.walk.circle": [1.17, 1.17],
    "figure.walk.circle.fill": [1.17, 1.17],
    "figure.yoga": [1.26, 1.255],
    "film": [1.405, 1.07],
    "film.fill": [1.405, 1.07],
    "fish": [1.63, 1.315],
    "fish.fill": [1.61, 1.29],
    "flag": [1.13, 1.13],
    "flag.fill": [1.13, 1.13],
    "flame": [0.985, 1.23],
    "flame.fill": [0.985, 1.23],
    "folder": [1.36, 1.065],
    "folder.fill": [1.36, 1.065],
    "fork.knife": [0.92, 1.305],
    "forward": [1.475, 0.92],
    "forward.end": [1, 0.92],
    "forward.end.fill": [1.155, 0.92],
    "forward.fill": [1.475, 0.92],
    "fuelpump": [1.235, 1.26],
    "fuelpump.fill": [1.235, 1.26],
    "gamecontroller": [1.66, 1.055],
    "gamecontroller.fill": [1.66, 1.055],
    "gauge": [1.17, 1.17],
    "gauge.medium": [1.17, 1.17],
    "gear": [1.295, 1.295],
    "gearshape": [1.215, 1.215],
    "gearshape.fill": [1.19, 1.195],
    "gift": [1.19, 1.195],
    "gift.fill": [1.19, 1.195],
    "globe": [1.17, 1.17],
    "globe.americas": [1.17, 1.17],
    "globe.americas.fill": [1.17, 1.17],
    "globe.fill": [1.175, 1.16],
    "graduationcap": [1.58, 1.365],
    "graduationcap.fill": [1.56, 1.355],
    "guitars": [1.505, 1.26],
    "guitars.fill": [1.5, 1.265],
    "hammer": [1.465, 1.395],
    "hammer.fill": [1.415, 1.325],
    "hand.raised": [1.185, 1.235],
    "hand.raised.fill": [1.185, 1.215],
    "hand.thumbsup": [1.165, 1.235],
    "hand.thumbsup.fill": [1.175, 1.17],
    "hands.clap": [1.495, 1.415],
    "hands.clap.fill": [1.525, 1.48],
    "hare": [1.765, 1.27],
    "hare.fill": [1.715, 1.225],
    "headphones": [1.245, 1.21],
    "heart": [1.22, 1.07],
    "heart.fill": [1.22, 1.07],
    "heart.text.square": [1.15, 1.07],
    "heart.text.square.fill": [1.15, 1.07],
    "hourglass": [0.825, 1.07],
    "house": [1.42, 1.2],
    "house.and.flag.fill": [1.805, 1.245],
    "house.fill": [1.42, 1.2],
    "house.lodge": [2.25, 1.02],
    "house.lodge.fill": [2.245, 1.17],
    "hurricane": [0.795, 1.19],
    "icloud": [1.4, 1.02],
    "icloud.fill": [1.4, 1.02],
    "info.circle": [1.17, 1.17],
    "info.circle.fill": [1.17, 1.17],
    "internaldrive": [1.405, 1.005],
    "internaldrive.fill": [1.375, 0.99],
    "iphone": [1, 1.205],
    "key": [0.905, 1.395],
    "key.fill": [0.875, 1.38],
    "keyboard": [1.48, 0.945],
    "keyboard.fill": [1.48, 0.945],
    "ladybug": [1.36, 1.335],
    "ladybug.fill": [1.36, 1.34],
    "laptopcomputer": [1.66, 0.965],
    "leaf": [1.205, 1.09],
    "leaf.fill": [1.225, 1.075],
    "lightbulb": [0.905, 1.31],
    "lightbulb.fill": [0.905, 1.31],
    "link": [1.26, 1.27],
    "list.bullet": [1.235, 0.885],
    "list.number": [1.235, 0.995],
    "location": [1.16, 1.145],
    "location.circle": [1.17, 1.17],
    "location.circle.fill": [1.17, 1.17],
    "location.fill": [1.16, 1.135],
    "location.slash": [1.16, 1.19],
    "location.slash.fill": [1.16, 1.19],
    "lock": [0.94, 1.13],
    "lock.fill": [0.94, 1.13],
    "lock.open": [1.255, 1.13],
    "lock.open.fill": [1.255, 1.13],
    "lock.shield": [1.065, 1.16],
    "lock.shield.fill": [1.05, 1.145],
    "lungs": [1.54, 1.115],
    "lungs.fill": [1.54, 1.115],
    "magnifyingglass": [1.175, 1.135],
    "map": [1.27, 1.135],
    "map.circle": [1.17, 1.17],
    "map.circle.fill": [1.17, 1.17],
    "map.fill": [1.27, 1.13],
    "mappin": [0.94, 1.21],
    "mappin.and.ellipse": [1.1, 1.325],
    "medal": [1.175, 1.285],
    "medal.fill": [1.18, 1.275],
    "megaphone": [1.34, 1.21],
    "megaphone.fill": [1.34, 1.215],
    "memorychip": [1.3, 1.02],
    "memorychip.fill": [1.3, 1.02],
    "message": [1.31, 1.125],
    "message.fill": [1.3, 1.11],
    "mic": [1, 1.215],
    "mic.fill": [1, 1.21],
    "minus": [1.06, 0.26],
    "minus.circle": [1.17, 1.17],
    "minus.circle.fill": [1.17, 1.17],
    "moon": [1.15, 1.17],
    "moon.fill": [1.15, 1.17],
    "moon.stars": [1.07, 1.19],
    "moon.stars.fill": [1.06, 1.185],
    "mosaic": [1.15, 1.07],
    "mosaic.fill": [1.15, 1.07],
    "mountain.2": [1.92, 1.05],
    "mountain.2.fill": [1.92, 1.2],
    "music.mic": [1.195, 1.185],
    "music.note": [0.85, 1.155],
    "music.note.list": [1.25, 1.155],
    "network": [1.17, 1.17],
    "newspaper": [1.365, 1.22],
    "newspaper.fill": [1.345, 1.22],
    "note.text": [1.225, 1.07],
    "paintbrush": [1.265, 1.375],
    "paintbrush.fill": [1.255, 1.37],
    "paintpalette": [1.35, 1.15],
    "paintpalette.fill": [1.35, 1.15],
    "paperclip": [1.16, 1.275],
    "paperplane": [1.225, 1.195],
    "paperplane.fill": [1.225, 1.195],
    "parkingsign": [0.87, 1.1],
    "party.popper.fill": [1.49, 1.395],
    "pause": [0.66, 0.98],
    "pause.circle": [1.17, 1.17],
    "pause.circle.fill": [1.17, 1.17],
    "pause.fill": [0.85, 0.98],
    "pawprint": [1.31, 1.205],
    "pawprint.fill": [1.28, 1.17],
    "pencil": [1.005, 0.955],
    "person": [1.105, 1.075],
    "person.2": [1.615, 1.145],
    "person.2.fill": [1.585, 1.115],
    "person.2.wave.2.fill": [1.765, 1.26],
    "person.badge.key": [1.105, 1.26],
    "person.badge.key.fill": [1.075, 1.245],
    "person.crop.circle": [1.17, 1.17],
    "person.crop.circle.fill": [1.17, 1.17],
    "person.fill": [1.075, 1.05],
    "phone": [1.175, 1.125],
    "phone.fill": [1.13, 1.085],
    "photo": [1.405, 1.07],
    "photo.fill": [1.405, 1.07],
    "pills": [1.38, 1.205],
    "pills.fill": [1.375, 1.175],
    "pin": [1.15, 1.31],
    "pin.fill": [1.15, 1.31],
    "play": [0.875, 0.99],
    "play.circle": [1.17, 1.17],
    "play.circle.fill": [1.17, 1.17],
    "play.fill": [0.875, 0.99],
    "plus": [1.06, 0.98],
    "plus.circle": [1.17, 1.17],
    "plus.circle.fill": [1.17, 1.17],
    "popcorn": [1.085, 1.405],
    "popcorn.fill": [1.075, 1.475],
    "power": [1.17, 1.195],
    "printer": [1.355, 1.225],
    "printer.fill": [1.355, 1.29],
    "puzzlepiece": [1.69, 1.115],
    "puzzlepiece.fill": [1.665, 1.11],
    "qrcode": [1.15, 1.07],
    "questionmark.circle": [1.17, 1.17],
    "questionmark.circle.fill": [1.17, 1.17],
    "quote.bubble": [1.33, 1.18],
    "quote.bubble.fill": [1.33, 1.185],
    "quote.opening": [1.325, 0.85],
    "rainbow": [1.6, 0.92],
    "rectangle.3.group.fill": [1.605, 1.06],
    "rectangle.fill": [1.405, 1.07],
    "rectangle.stack": [1.275, 1.33],
    "rectangle.stack.fill": [1.275, 1.33],
    "repeat": [1.295, 1.04],
    "rosette": [1.03, 1.265],
    "safari": [1.17, 1.17],
    "safari.fill": [1.17, 1.17],
    "sailboat": [1.325, 1.52],
    "sailboat.fill": [1.325, 1.52],
    "scissors": [1.505, 1.165],
    "scope": [1.36, 1.36],
    "screwdriver": [1.455, 1.42],
    "screwdriver.fill": [1.43, 1.395],
    "scribble.variable": [1.24, 1.195],
    "shield": [1.065, 1.16],
    "shield.fill": [1.05, 1.145],
    "shippingbox": [1.24, 1.25],
    "shippingbox.fill": [1.245, 1.235],
    "signpost.right": [1.225, 1.2],
    "signpost.right.fill": [1.225, 1.2],
    "smoke": [1.3, 1.03],
    "smoke.fill": [1.29, 1.09],
    "snowflake": [1.04, 1.16],
    "sofa": [1.765, 1.03],
    "sofa.fill": [1.74, 1.03],
    "sparkle": [1.155, 1.125],
    "sparkles": [1.105, 1.285],
    "sparkles.rectangle.stack": [1.275, 1.33],
    "speaker.wave.2": [1.39, 1.035],
    "speaker.wave.2.fill": [1.39, 1.035],
    "square": [1.15, 1.07],
    "square.and.arrow.up": [1.12, 1.345],
    "square.and.arrow.up.fill": [1.12, 1.27],
    "square.and.pencil": [1.215, 1.215],
    "square.dashed": [1.15, 1.07],
    "square.fill": [1.15, 1.07],
    "square.grid.2x2": [1.15, 1.07],
    "square.grid.2x2.fill": [1.15, 1.07],
    "square.grid.3x1.folder.badge.plus": [1.36, 1.15],
    "square.grid.3x3.fill": [1.21, 1.11],
    "square.on.circle": [1.325, 1.25],
    "star": [1.29, 1.215],
    "star.fill": [1.29, 1.215],
    "staroflife": [1.13, 1.205],
    "staroflife.fill": [1.105, 1.195],
    "stop": [1.05, 0.97],
    "stop.fill": [1.05, 0.97],
    "stopwatch": [1.17, 1.265],
    "stopwatch.fill": [1.17, 1.265],
    "storefront": [1.375, 1.245],
    "storefront.fill": [1.32, 1.245],
    "suitcase": [1.385, 1.12],
    "suitcase.fill": [1.385, 1.12],
    "suitcase.rolling": [1.025, 1.475],
    "suitcase.rolling.fill": [1.025, 1.475],
    "sun.haze": [1.375, 1.325],
    "sun.haze.fill": [1.38, 1.325],
    "sun.horizon.fill": [1.505, 0.97],
    "sun.max": [1.23, 1.23],
    "sun.max.fill": [1.23, 1.23],
    "sun.min": [1.14, 1.14],
    "sun.min.fill": [1.14, 1.14],
    "sunrise": [1.505, 1.325],
    "sunrise.fill": [1.505, 1.27],
    "sunset": [1.505, 1.325],
    "sunset.fill": [1.505, 1.27],
    "tag": [1.315, 1.28],
    "tag.fill": [1.315, 1.28],
    "target": [1.17, 1.17],
    "text.alignleft": [1.235, 1.015],
    "theatermasks": [1.9, 1.335],
    "theatermasks.fill": [1.905, 1.405],
    "thermometer": [0.765, 1.255],
    "thermometer.sun": [1.035, 1.43],
    "thermometer.sun.fill": [1.035, 1.485],
    "ticket": [1.46, 1.015],
    "ticket.fill": [1.46, 1.015],
    "timer": [1.17, 1.17],
    "tornado": [1.1, 1.245],
    "tortoise": [1.895, 1],
    "tortoise.fill": [1.86, 0.98],
    "touchid": [1.25, 1.235],
    "tram": [1.14, 1.4],
    "tram.fill": [1.075, 1.38],
    "trash": [1.095, 1.26],
    "trash.fill": [1.095, 1.26],
    "tray": [1.405, 1.005],
    "tray.fill": [1.405, 1.005],
    "tree": [1.515, 1.445],
    "tree.fill": [1.515, 1.445],
    "trophy": [1.205, 1.24],
    "trophy.fill": [1.205, 1.24],
    "tv": [1.475, 1.15],
    "tv.fill": [1.475, 1.15],
    "umbrella": [1.225, 1.3],
    "umbrella.fill": [1.225, 1.3],
    "video": [1.425, 0.975],
    "video.fill": [1.425, 0.965],
    "wallet.pass": [1.075, 1.22],
    "wallet.pass.fill": [1.075, 1.22],
    "wand.and.stars": [1.235, 1.14],
    "wave.3.right": [0.88, 1.39],
    "waveform": [1.15, 1.195],
    "waveform.path": [1.4, 1.305],
    "waveform.path.ecg": [1.18, 1.195],
    "wifi": [1.315, 0.98],
    "wifi.slash": [1.315, 1.2],
    "wind": [1.225, 1.04],
    "wrench": [1.36, 1.385],
    "wrench.fill": [1.36, 1.385],
    "xmark": [1.025, 0.955],
    "xmark.circle": [1.17, 1.17],
    "xmark.circle.fill": [1.17, 1.17],
    "zzz": [1.08, 1.195]
  });

  // ../Web/preview-engine/src/render/symbolShapes.js
  var roundedRect = (x, y, w, h, r) => `M${x + r} ${y}H${x + w - r}A${r} ${r} 0 0 1 ${x + w} ${y + r}V${y + h - r}A${r} ${r} 0 0 1 ${x + w - r} ${y + h}H${x + r}A${r} ${r} 0 0 1 ${x} ${y + h - r}V${y + r}A${r} ${r} 0 0 1 ${x + r} ${y}Z`;
  var star = (cx, cy, r, pinch = 0.14) => {
    const k = r * pinch;
    return `M${cx} ${cy - r}Q${cx + k} ${cy - k} ${cx + r} ${cy}Q${cx + k} ${cy + k} ${cx} ${cy + r}Q${cx - k} ${cy + k} ${cx - r} ${cy}Q${cx - k} ${cy - k} ${cx} ${cy - r}Z`;
  };
  var ellipse = (cx, cy, rx, ry) => `M${cx - rx} ${cy}A${rx} ${ry} 0 1 0 ${cx + rx} ${cy}A${rx} ${ry} 0 1 0 ${cx - rx} ${cy}Z`;
  var spokes = (cx, cy, r, angles) => angles.map((a2) => `M${cx} ${cy}L${(cx + r * Math.cos(a2 * Math.PI / 180)).toFixed(2)} ${(cy + r * Math.sin(a2 * Math.PI / 180)).toFixed(2)}`).join("");
  var dots = (cells) => cells.map(([x, y]) => `<rect x="${x}" y="${y}" width="1.5" height="1.4" rx="0.35"/>`).join("");
  var calendarBody = (dy = 0) => `<path fill-rule="evenodd" d="${roundedRect(1.5, 2 + dy, 21, 19.6, 3.2)}${roundedRect(3, 7 + dy, 18, 13.1, 1.4)}"/>` + dots([[9.5, 9.6], [13, 9.6], [16.5, 9.6], [5.5, 13.1], [9.5, 13.1], [13, 13.1], [16.5, 13.1], [5.5, 16.6], [9.5, 16.6], [13, 16.6]].map(([x, y]) => [x, y + dy]));
  var horizon = (arrow) => `<path d="${arrow}M4.4 8.8L6.6 11.1M19.6 8.8L17.4 11.1M0 17H3.3M20.7 17H24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/><path d="M6.3 18.7A5.7 5.7 0 0 1 17.7 18.7Z${roundedRect(-1.5, 19.9, 27, 1.7, 0.85)}"/>`;
  var symbolShapes = Object.freeze({
    calendar: () => calendarBody(),
    "moon.stars.fill": () => `<path d="M9 5.5A9.3 9.3 0 1 0 20.5 17.5A9.33 9.33 0 0 1 9 5.5Z"/><path d="${star(15.2, 3.4, 2.3)}${star(21, 9.5, 4)}"/>`,
    "mosaic.fill": (id) => `<defs><mask id="${id}" maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24"><rect width="24" height="24" fill="white"/><path d="M15.5 0V24M0 14.75H24M15.5 8.25H24M8.25 14.75V24" stroke="black" stroke-width="0.95"/></mask></defs><path mask="url(#${id})" d="${roundedRect(2, 2, 19.3, 18.6, 3)}"/>`,
    sparkles: () => `<path d="${star(13.5, 15.6, 8.2)}${star(6.1, 8, 4.1)}${star(11.25, 2, 2.5)}"/>`,
    // Wider than the 24-unit box, like the symbol itself.
    "battery.100": () => `<path fill-rule="evenodd" d="${roundedRect(-3, 5, 27, 14.3, 4.3)}${roundedRect(-1.5, 6.6, 24, 11.1, 2.8)}"/><path d="${roundedRect(-0.8, 8, 21.8, 8.3, 1.5)}${roundedRect(26, 9.5, 1.3, 5, 0.65)}"/>`,
    timer: () => `<path d="M11.75 2A9.75 9.75 0 1 1 4.74 4.98" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><path d="M11.75 2V6.3" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/><path d="M12.87 12.33L6.96 6.18L6.64 6.42L11.13 13.67Z"/><circle cx="12" cy="13" r="1.1"/>`,
    checklist: (id) => `<defs><mask id="${id}" maskUnits="userSpaceOnUse" x="-2" y="-2" width="28" height="28"><rect x="-2" y="-2" width="28" height="28" fill="white"/><path d="M2.4 5.9L3.9 7.4L6.7 4.4" fill="none" stroke="black" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"/></mask></defs><circle mask="url(#${id})" cx="4.5" cy="5.75" r="4.25"/><circle cx="4.5" cy="14.75" r="3.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="${roundedRect(11.5, 4.9, 12.5, 1.8, 0.9)}${roundedRect(11.5, 13.9, 12.5, 1.8, 0.9)}"/>`,
    "books.vertical.fill": () => `<path fill-rule="evenodd" d="${roundedRect(-1, 3, 4.5, 20, 1)}${roundedRect(5, 7, 6.5, 16.5, 1)}${roundedRect(7, 9.4, 3, 1, 0.3)}${roundedRect(7, 20, 3, 1, 0.3)}${roundedRect(13, 0, 5.5, 23, 1)}"/><path d="M19.8 3.3L22.8 3L24.8 23.4L21.6 23.6Z" stroke="currentColor" stroke-width="0.8" stroke-linejoin="round"/>`,
    // The screen is the symbol's secondary layer, drawn dimmed.
    desktopcomputer: () => `<path fill-rule="evenodd" d="${roundedRect(-1, 1.5, 25.5, 16.8, 2)}${roundedRect(0.6, 3, 22.4, 10.8, 0.6)}"/><path fill-opacity="0.35" d="${roundedRect(0.6, 3, 22.4, 10.8, 0.6)}"/><path d="M8.5 18H15V20.2H8.5Z${roundedRect(7.5, 20, 8.5, 1.8, 0.9)}"/>`,
    "banknote.fill": () => `<path fill-rule="evenodd" d="${roundedRect(-2.5, 3, 28.5, 17.5, 2.2)}${roundedRect(-1, 4.6, 25.5, 14.4, 1)}${roundedRect(0.5, 6.5, 23.5, 10.5, 0.5)}${ellipse(12.25, 12, 3.6, 5.2)}${ellipse(12.25, 12, 2.7, 4.1)}"/>`,
    "chart.pie.fill": (id) => `<defs><mask id="${id}" maskUnits="userSpaceOnUse" x="-2" y="-2" width="28" height="28"><rect x="-2" y="-2" width="28" height="28" fill="white"/><path d="${spokes(11.75, 11.75, 13, [-90, 38])}" stroke="black" stroke-width="1.1"/><path d="${spokes(11.75, 11.75, 13, [-19])}" stroke="black" stroke-width="1.6"/></mask></defs><circle mask="url(#${id})" cx="11.75" cy="11.75" r="10.75"/>`,
    "fork.knife": () => `<path d="${roundedRect(4.6, -0.5, 1.5, 8.5, 0.75)}${roundedRect(7.4, -0.5, 1.5, 8.5, 0.75)}${roundedRect(10.4, -0.5, 1.5, 8.5, 0.75)}M4.6 7H11.9V7.6Q11.9 10 9.6 10.4H6.9Q4.6 10 4.6 7.6Z${roundedRect(7, 9, 2.5, 15, 1.25)}"/><path d="M18.5 -0.5Q19 -0.5 19 0.5V23Q19 24 18 24Q17 24 17 23V14.5L15.6 13.6Q15 13.3 15 12.5V7Q15 1.5 18.5 -0.5Z"/>`,
    "flame.fill": () => `<path fill-rule="evenodd" d="M5.6 0.5C9 0.5 20.5 7 20.5 14.5C20.5 20 16.5 23.5 11.5 23.5C6.5 23.5 3 20 3 15C3 11 4.8 8.5 5.8 6.8C6.3 7.8 7 7.9 7.2 7.2C7.8 4.5 6.5 2 5.6 0.5ZM12.5 11.5C14.5 13.5 15.2 15 15.2 16.5C15.2 18.5 13.8 20 12 20C10.2 20 8.8 18.7 8.8 16.9C8.8 15.8 9.3 15 9.8 14.4C10.3 15 10.8 15 11.1 14.4C11.8 13.3 12.3 12.4 12.5 11.5Z"/>`,
    "cloud.rain.fill": () => `<circle cx="11.5" cy="7.5" r="8"/><circle cx="4.7" cy="11.2" r="4.4"/><circle cx="20" cy="10.3" r="5.2"/><rect x="4.7" y="9" width="15.3" height="6.5"/><path d="M6.4 16.2L5.1 18.8M11 16.2L9.7 18.8M15.8 16.2L14.5 18.8M20.5 16.2L19.2 18.8M8.6 20.3L7.6 22.5M17.6 20.3L16.6 22.5" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>`,
    "battery.100.bolt": (id) => `<defs><mask id="${id}" maskUnits="userSpaceOnUse" x="-6" y="-2" width="36" height="28"><rect x="-6" y="-2" width="36" height="28" fill="white"/><path d="M12.8 4.6L6.6 12.6H11L8.3 19.4L14.9 11.2H10.6Z" fill="black" stroke="black" stroke-width="2.6" stroke-linejoin="round"/></mask></defs><g mask="url(#${id})"><path fill-rule="evenodd" d="${roundedRect(-3, 5, 27, 14.3, 4.3)}${roundedRect(-1.5, 6.6, 24, 11.1, 2.8)}"/><path d="${roundedRect(-0.8, 8, 21.8, 8.3, 1.5)}${roundedRect(26, 9.5, 1.3, 5, 0.65)}"/></g><path d="M12.8 4.6L6.6 12.6H11L8.3 19.4L14.9 11.2H10.6Z" stroke="currentColor" stroke-width="0.6" stroke-linejoin="round"/>`,
    "quote.opening": () => `<path d="${ellipse(5.7, 14, 5.3, 4.7)}${ellipse(18.6, 14, 5.3, 4.7)}"/><path d="M1.6 12Q1.6 6.4 7.6 5.2M14.5 12Q14.5 6.4 20.5 5.2" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/>`,
    "graduationcap.fill": () => `<path fill-rule="evenodd" d="M12 -1L26.5 6.5L12 13.5L-2.5 6.5Z${ellipse(12, 5.6, 3, 1)}" stroke="currentColor" stroke-width="0.8" stroke-linejoin="round"/><path d="M4.5 11.8L12 15.3L22.5 11.3V16.4Q14 19.8 6 19.2Q4.5 18.8 4.5 17.5Z"/><path d="M12 6.5L2 8.5V17" fill="none" stroke="currentColor" stroke-width="1"/><path d="${roundedRect(2.5, 19.6, 2.6, 4.2, 0.8)}"/>`,
    "bed.double.fill": () => `<path fill-rule="evenodd" d="${roundedRect(1, 3, 22, 7, 2.5)}${roundedRect(4.5, 6, 5, 4, 1)}${roundedRect(14.5, 6, 5, 4, 1)}"/><path d="${roundedRect(-1.5, 9, 27, 8.2, 2.2)}${roundedRect(-1.5, 15, 2, 4.5, 0.6)}${roundedRect(23.5, 15, 2, 4.5, 0.6)}"/>`,
    "suitcase.rolling.fill": () => `<path fill-rule="evenodd" d="${roundedRect(7.1, -2.5, 10.6, 8, 2.2)}${roundedRect(8.8, -0.9, 7.2, 8, 1)}"/><path d="${roundedRect(3.5, 4, 17, 19, 2.2)}${roundedRect(6, 22, 3, 3.2, 1.2)}${roundedRect(15.3, 22, 3, 3.2, 1.2)}"/>`,
    "figure.run": () => `<circle cx="14.6" cy="2.2" r="2.2"/><path d="M14 5.6L12.3 11.6" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round"/><path d="M13 6.2L8.4 6.4L7 10.4M13.6 6.4L16.6 9L21 8.6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M12.5 11.8L16.6 15.5L13.6 19M12.3 12L9.4 15.5L7.6 19.8L4 22.6" fill="none" stroke="currentColor" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round"/>`,
    "calendar.badge.exclamationmark": (id) => `<defs><mask id="${id}" maskUnits="userSpaceOnUse" x="-2" y="-2" width="32" height="28"><rect x="-2" y="-2" width="32" height="28" fill="white"/><circle cx="22" cy="16.5" r="6.4" fill="black"/></mask><mask id="${id}b" maskUnits="userSpaceOnUse" x="-2" y="-2" width="32" height="28"><rect x="-2" y="-2" width="32" height="28" fill="white"/><path d="M22 12.6V16.8" stroke="black" stroke-width="1.5" stroke-linecap="round"/><circle cx="22" cy="19.4" r="0.85" fill="black"/></mask></defs><g mask="url(#${id})">${calendarBody(-1.5)}</g><circle mask="url(#${id}b)" cx="22" cy="16.5" r="5"/>`,
    "video.fill": () => `<path d="${roundedRect(-0.5, 3, 18.5, 17.5, 3.2)}M19.5 9.6L24.3 5.3Q26 4.3 26 6.4V16.8Q26 18.6 24.3 17.6L19.5 13.7Z"/>`,
    "forward.fill": () => `<path d="M-1.5 5.3Q-1.5 3.7 0 4.6L12.4 11.1Q13.2 11.6 12.4 12.1L0 19.4Q-1.5 20.3 -1.5 18.7ZM13 5.3Q13 3.7 14.5 4.6L26.9 11.1Q27.7 11.6 26.9 12.1L14.5 19.4Q13 20.3 13 18.7Z"/>`,
    "backward.fill": () => `<path transform="translate(24 0) scale(-1 1)" d="M-1.5 5.3Q-1.5 3.7 0 4.6L12.4 11.1Q13.2 11.6 12.4 12.1L0 19.4Q-1.5 20.3 -1.5 18.7ZM13 5.3Q13 3.7 14.5 4.6L26.9 11.1Q27.7 11.6 26.9 12.1L14.5 19.4Q13 20.3 13 18.7Z"/>`,
    "house.fill": () => `<path d="M-0.3 11.2L10.6 1.6Q12 0.4 13.4 1.6L24.3 11.2" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/><path d="${roundedRect(19.3, 3.5, 2.3, 6.5, 0.4)}"/><path fill-rule="evenodd" d="M12 5L21 13V21.3Q21 23 19.3 23H4.2Q2.5 23 2.5 21.3V13Z${roundedRect(9.6, 14.6, 5.4, 7.4, 1.2)}"/>`,
    "briefcase.fill": () => `<path fill-rule="evenodd" d="${roundedRect(7, 1.5, 10.5, 6, 2)}${roundedRect(8.6, 3, 7.3, 6, 1)}"/><path d="${roundedRect(-0.5, 5.5, 25.5, 6.6, 2.4)}${roundedRect(-0.5, 13.6, 25.5, 8, 2.4)}"/>`,
    airplane: () => `<path d="${roundedRect(1, 9.9, 24, 3.4, 1.7)}M6.3 1.2L7.8 0.9L18.8 10H9.6ZM6.3 22L7.8 22.3L18.8 13.2H9.6ZM1 7H2.6L5.2 10.2H1ZM1 16.5H2.6L5.2 13H1Z"/>`,
    "sunrise.fill": () => horizon(`M12 7.5V1.5M8.6 4.4L12 1.1L15.4 4.4`),
    "sunset.fill": () => horizon(`M12 0.8V7.2M8.6 4.2L12 7.6L15.4 4.2`),
    "arrow.clockwise": () => `<path d="M14.63 5.39A9 9 0 1 0 21 13.2M11.2 0.8L15.3 4.8L11.4 9" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>`,
    "figure.walk": () => `<circle cx="12" cy="1.6" r="2.2"/><path d="M11.5 4.8L11 12.4" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"/><path d="M10 5.8L6.3 9V12.4M12.4 7.2L14.6 9.4H19.6" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/><path d="M11.5 13L16 22.6M10.2 14.6L5.3 22.3" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>`,
    "chevron.left.forwardslash.chevron.right": () => `<path d="M5.2 5.2L-1.9 12L5.2 18.8M18.8 5.2L25.9 12L18.8 18.8M14.4 2.4L9.3 21.4" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"/>`,
    "chart.line.uptrend.xyaxis": () => `<path d="M1.5 2.3V21H20.8M2 12.4L6.8 8.6L12.8 13.6L18 8.6" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/><path d="M15.8 6.1L22.8 4.2L21 11Z" stroke="currentColor" stroke-width="0.8" stroke-linejoin="round"/>`,
    "cloud.fill": () => `<circle cx="11.5" cy="10.5" r="7"/><circle cx="19.5" cy="13.3" r="5.5"/><circle cx="4.3" cy="14.8" r="4.8"/><rect x="4.3" y="12" width="15.2" height="7.6"/>`,
    "bolt.fill": () => `<path d="M15 -0.2L4.8 13.6H11.6L8.2 24.2L19.2 10.1H12.4Z" stroke="currentColor" stroke-width="0.8" stroke-linejoin="round"/>`,
    "wand.and.stars": (id) => `<defs><mask id="${id}" maskUnits="userSpaceOnUse" x="-2" y="-2" width="28" height="28"><rect x="-2" y="-2" width="28" height="28" fill="white"/><path d="M6.9 4.5L12 10" stroke="black" stroke-width="0.9" stroke-linecap="round"/></mask></defs><path mask="url(#${id})" d="M6.9 4.5L12 10" fill="none" stroke="currentColor" stroke-width="2.7" stroke-linecap="round"/><path d="M12.6 10.6L21.2 21.2" fill="none" stroke="currentColor" stroke-width="2.7" stroke-linecap="round"/><path d="${star(16, 4.5, 3)}${star(3.9, 14.5, 2.7)}${star(8.2, 18.5, 1.8)}"/>`,
    hourglass: () => `<path d="M6 2.6H18Q18.3 2.6 18 4L16.8 7.2H7.2L6 4Q5.7 2.6 6 2.6ZM12 12.4L17.4 16.9H6.6Z${roundedRect(5.6, 20.4, 12.8, 1.3, 0.6)}" stroke="currentColor" stroke-width="0.6" stroke-linejoin="round"/><path d="M7.6 7.4L11.6 12.6M16.4 7.4L12.4 12.6M8 16.6L5.9 20.4M16 16.6L18.1 20.4" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>`,
    magnifyingglass: () => `<circle cx="10" cy="9.5" r="7.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M15.6 15.4L21 20.9" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round"/>`,
    "music.note": () => `<path d="M11 3.4L17 1.6Q18.6 1.2 18.6 2.8V6.4L11 8.6Z${roundedRect(11, 3, 1.5, 15.5, 0.5)}${ellipse(8.9, 19.6, 3.5, 2.7)}"/>`,
    "arrow.up.right": () => `<path d="M8 4.9H18.7V16.4M18.4 5.2L5 18.8" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>`,
    "arrow.down.right": () => `<path d="M8 19.1H18.7V7.6M18.4 18.8L5 5.2" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>`,
    "leaf.fill": (id) => `<defs><mask id="${id}" maskUnits="userSpaceOnUse" x="-2" y="-2" width="28" height="28"><rect x="-2" y="-2" width="28" height="28" fill="white"/><path d="M6.8 5.8Q13 9.5 19.6 11.2" fill="none" stroke="black" stroke-width="1.1" stroke-linecap="round"/></mask></defs><path mask="url(#${id})" d="M0.6 2.5C10 2 20.5 3 21.4 9.5C22 15 18 19.8 12 19.8C6 19.8 2 15.5 1.2 9.5C0.9 7 0.6 4.5 0.6 2.5Z"/><path d="M19.4 14.8L22.6 21.2" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>`,
    "sun.max.fill": () => `<circle cx="12" cy="12" r="5.2"/><path d="M20.30 12.00L23.30 12.00M17.59 17.59L19.35 19.35M12.00 20.30L12.00 23.30M6.41 17.59L4.65 19.35M3.70 12.00L0.70 12.00M6.41 6.41L4.65 4.65M12.00 3.70L12.00 0.70M17.59 6.41L19.35 4.65" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>`,
    "face.smiling": () => `<circle cx="11.75" cy="11.75" r="10.1" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="${ellipse(8.8, 8.9, 1.2, 1.6)}${ellipse(15.2, 8.9, 1.2, 1.6)}"/><path d="M7.9 14.2Q11.8 18.6 15.7 14.2" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>`,
    "cloud.sun.fill": (id) => `<defs><mask id="${id}" maskUnits="userSpaceOnUse" x="-6" y="-4" width="36" height="32"><rect x="-6" y="-4" width="36" height="32" fill="white"/><g fill="black" stroke="black" stroke-width="2.6"><circle cx="6.3" cy="13.6" r="6.1"/><circle cx="14.8" cy="15.3" r="5.2"/><circle cx="1.8" cy="17.6" r="4"/><rect x="1.8" y="15" width="13" height="6.6"/></g></mask></defs><g mask="url(#${id})"><circle cx="17.5" cy="11" r="4.8"/><path d="M17.50 3.70L17.50 1.00M22.66 5.84L24.57 3.93M24.80 11.00L27.50 11.00M12.34 5.84L10.43 3.93M22.66 16.16L24.57 18.07M10.20 11.00L7.50 11.00" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></g><circle cx="6.3" cy="13.6" r="6.1"/><circle cx="14.8" cy="15.3" r="5.2"/><circle cx="1.8" cy="17.6" r="4"/><rect x="1.8" y="15" width="13" height="6.6"/>`,
    "drop.fill": () => `<path d="M11.75 1C13 3.5 19 9 19 14.6A7.25 7.25 0 0 1 4.5 14.6C4.5 9 10.5 3.5 11.75 1Z"/>`,
    "birthday.cake.fill": () => `<path d="${ellipse(11.9, 1.6, 1.2, 1.7)}M11.4 3H12.6V9H11.4Z${roundedRect(5, 9, 14, 4, 1.2)}${roundedRect(1.5, 13, 21, 4.2, 1.2)}${roundedRect(1.5, 18.8, 21, 3.6, 0.5)}${roundedRect(-0.5, 22, 24.5, 2, 1)}"/>`,
    "heart.text.square.fill": (id) => `<defs><mask id="${id}" maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24"><rect width="24" height="24" fill="white"/><path fill="black" d="M8 9.6C4.9 7.5 4.9 4.4 6.8 4.4C7.6 4.4 8 5.1 8 5.1C8 5.1 8.4 4.4 9.2 4.4C11.1 4.4 11.1 7.5 8 9.6Z${roundedRect(5.5, 13.3, 11.5, 1.5, 0.75)}${roundedRect(5.5, 17.3, 8.5, 1.5, 0.75)}"/></mask></defs><path mask="url(#${id})" d="${roundedRect(2, 2, 19.5, 19.5, 3.4)}"/>`,
    "globe.americas.fill": () => `<circle cx="11.75" cy="11.75" r="10.2" fill="none" stroke="currentColor" stroke-width="1.7"/><path d="M4.5 6L6.5 3.5L11 1.8L16.5 2.2L17.5 4L15 5.2L14 7.5L12 8.5L10 9L8.3 8L6 7ZM10.5 10L17 10.5L18.2 12.5L17.5 15L15 17L13.5 18L12.5 15.5L11.3 12.5Z" stroke="currentColor" stroke-width="0.8" stroke-linejoin="round"/>`
  });

  // ../Web/preview-engine/src/render/icons.generated.js
  var sfSymbolToLucide = { "airplane": "plane", "alarm": "alarm-clock", "alarm.waves.left.and.right": "alarm-clock", "ant": "bug", "antenna.radiowaves.left.and.right": "radio-tower", "app.badge": "app-window", "applewatch": "watch", "archivebox": "archive", "arrow.clockwise": "rotate-cw", "arrow.counterclockwise": "rotate-ccw", "arrow.down": "arrow-down", "arrow.down.right": "arrow-down-right", "arrow.left": "arrow-left", "arrow.right": "arrow-right", "arrow.triangle.2.circlepath": "refresh-cw", "arrow.up": "arrow-up", "arrow.up.arrow.down": "arrow-up-down", "arrow.up.right": "arrow-up-right", "backward": "rewind", "backward.end": "skip-back", "bag": "shopping-bag", "banknote": "banknote", "battery.0": "battery", "battery.100": "battery-full", "battery.100.bolt": "battery-charging", "battery.25": "battery-low", "battery.50": "battery-medium", "battery.75": "battery-medium", "bed": "bed", "bed.double": "bed-double", "bed.double.circle": "bed-double", "bell": "bell", "bell.badge": "bell-dot", "bell.slash": "bell-off", "bicycle": "bike", "bird": "bird", "birthday.cake": "cake", "bolt": "zap", "bolt.car": "car", "bolt.heart": "heart-pulse", "bonjour": "radio", "book": "book", "book.closed": "book", "bookmark": "bookmark", "books.vertical": "library", "brain": "brain", "briefcase": "briefcase", "bubble.left": "message-circle", "bubble.left.and.bubble.right": "messages-square", "building.2": "building", "building.columns": "landmark", "bus": "bus", "calendar": "calendar", "calendar.badge.clock": "calendar-clock", "calendar.badge.exclamationmark": "calendar-x", "calendar.badge.plus": "calendar-plus", "calendar.circle": "calendar", "camera": "camera", "camera.macro": "flower", "car": "car", "carrot": "carrot", "cart": "shopping-cart", "cart.badge.plus": "shopping-cart", "chart.bar": "chart-column", "chart.line.uptrend.xyaxis": "chart-line", "chart.pie": "chart-pie", "chart.xyaxis.line": "chart-line", "checklist": "list-checks", "checkmark": "check", "checkmark.circle": "circle-check", "checkmark.seal": "badge-check", "checkmark.square": "square-check", "chevron.down": "chevron-down", "chevron.left": "chevron-left", "chevron.left.forwardslash.chevron.right": "code-xml", "chevron.right": "chevron-right", "chevron.up": "chevron-up", "circle": "circle", "circle.grid.2x2": "grid-2x2", "clock": "clock", "clock.arrow.circlepath": "rotate-ccw-clock", "cloud": "cloud", "cloud.bolt": "cloud-lightning", "cloud.drizzle": "cloud-drizzle", "cloud.fog": "cloud-fog", "cloud.moon": "cloud-moon", "cloud.rain": "cloud-rain", "cloud.snow": "cloud-snow", "cloud.sun": "cloud-sun", "cloud.sun.rain": "cloud-sun-rain", "cpu": "cpu", "creditcard": "credit-card", "cross": "cross", "crown": "crown", "cup": "cup-soda", "cup.and.saucer": "coffee", "desktopcomputer": "monitor", "dice": "dices", "doc": "file", "doc.text": "file-text", "dollarsign.circle": "circle-dollar-sign", "dot.radiowaves.left.and.right": "radio", "drop": "droplet", "drop.degreesign": "thermometer", "dumbbell": "dumbbell", "ellipsis": "ellipsis", "ellipsis.circle": "circle-ellipsis", "envelope": "mail", "envelope.open": "mail-open", "exclamationmark.circle": "circle-alert", "exclamationmark.triangle": "triangle-alert", "eye": "eye", "eye.slash": "eye-off", "eyedropper": "pipette", "face.smiling": "face-slightly-smiling", "faceid": "scan-face", "ferry": "ship", "figure.mind.and.body": "flower-2", "figure.run": "footprints", "figure.walk": "footprints", "figure.walk.circle": "footprints", "figure.yoga": "flower-2", "film": "film", "fish": "fish", "flag": "flag", "flame": "flame", "folder": "folder", "fork.knife": "utensils", "forward": "fast-forward", "forward.end": "skip-forward", "fuelpump": "fuel", "gamecontroller": "gamepad-2", "gauge": "gauge", "gauge.medium": "gauge", "gear": "settings", "gearshape": "settings", "gift": "gift", "globe": "globe", "globe.americas": "earth", "graduationcap": "graduation-cap", "guitars": "guitar", "hammer": "hammer", "hand.raised": "hand", "hand.thumbsup": "thumbs-up", "hands.clap": "party-popper", "hare": "rabbit", "headphones": "headphones", "heart": "heart", "heart.text.square": "heart-pulse", "hourglass": "hourglass", "house": "house", "house.lodge": "house", "hurricane": "tornado", "icloud": "cloud", "info.circle": "info", "internaldrive": "hard-drive", "iphone": "smartphone", "key": "key", "keyboard": "keyboard", "ladybug": "bug", "laptopcomputer": "laptop", "leaf": "leaf", "lightbulb": "lightbulb", "link": "link", "list.bullet": "list", "list.number": "list-ordered", "location": "navigation", "location.circle": "locate-fixed", "location.slash": "navigation-off", "lock": "lock", "lock.open": "lock-open", "lock.shield": "shield-check", "lungs": "wind", "magnifyingglass": "search", "map": "map", "map.circle": "map", "mappin": "map-pin", "mappin.and.ellipse": "map-pin", "medal": "medal", "megaphone": "megaphone", "memorychip": "memory-stick", "message": "message-circle", "mic": "mic", "minus": "minus", "minus.circle": "circle-minus", "moon": "moon", "moon.stars": "moon-star", "mosaic": "layout-grid", "mountain.2": "mountain", "music.mic": "mic-vocal", "music.note": "eighth-note", "music.note.list": "list-music", "network": "network", "newspaper": "newspaper", "note.text": "notebook-text", "paintbrush": "paintbrush", "paintpalette": "palette", "paperclip": "paperclip", "paperplane": "send", "parkingsign": "circle-parking", "pause": "pause", "pause.circle": "circle-pause", "pawprint": "paw-print", "pencil": "pencil", "person": "user", "person.2": "users", "person.badge.key": "key-round", "person.crop.circle": "circle-user", "phone": "phone", "photo": "image", "pills": "pill", "pin": "pin", "play": "play", "play.circle": "circle-play", "plus": "plus", "plus.circle": "circle-plus", "popcorn": "popcorn", "power": "power", "printer": "printer", "puzzlepiece": "puzzle", "qrcode": "qr-code", "questionmark.circle": "circle-question-mark", "quote.bubble": "message-square-quote", "quote.opening": "quote", "rainbow": "rainbow", "rectangle.stack": "layers", "repeat": "repeat", "rosette": "award", "safari": "compass", "sailboat": "sailboat", "scissors": "scissors", "scope": "crosshair", "screwdriver": "wrench", "shield": "shield", "shippingbox": "package", "signpost.right": "signpost", "smoke": "cloud", "snowflake": "snowflake", "sofa": "sofa", "sparkle": "sparkle", "sparkles": "sparkles", "speaker.wave.2": "volume-2", "square": "square", "square.and.arrow.up": "share", "square.and.pencil": "square-pen", "square.grid.2x2": "layout-grid", "star": "star", "staroflife": "asterisk", "stop": "square", "stopwatch": "timer", "storefront": "store", "suitcase": "briefcase", "suitcase.rolling": "luggage", "sun.haze": "haze", "sun.max": "sun", "sun.min": "sun-dim", "sunrise": "sunrise", "sunset": "sunset", "tag": "tag", "target": "target", "text.alignleft": "text-align-start", "theatermasks": "drama", "thermometer": "thermometer", "thermometer.sun": "thermometer-sun", "ticket": "ticket", "timer": "timer", "tornado": "tornado", "tortoise": "turtle", "touchid": "fingerprint-pattern", "tram": "tram-front", "trash": "trash", "tray": "inbox", "tree": "tree-pine", "trophy": "trophy", "tv": "tv", "umbrella": "umbrella", "video": "video", "wallet.pass": "wallet", "wand.and.stars": "wand-sparkles", "waveform": "audio-lines", "waveform.path.ecg": "activity", "wifi": "wifi", "wifi.slash": "wifi-off", "wind": "wind", "wrench": "wrench", "xmark": "x", "xmark.circle": "circle-x", "zzz": "moon" };
  var lucideIcons = { "plane": [["path", { "d": "M17.8 19.2 16 11l3.5-3.5C21 6 21.5 4 21 3c-1-.5-3 0-4.5 1.5L13 8 4.8 6.2c-.5-.1-.9.1-1.1.5l-.3.5c-.2.5-.1 1 .3 1.3L9 12l-2 3H4l-1 1 3 2 2 3 1-1v-3l3-2 3.5 5.3c.3.4.8.5 1.3.3l.5-.2c.4-.3.6-.7.5-1.2z" }]], "alarm-clock": [["circle", { "cx": "12", "cy": "13", "r": "8" }], ["path", { "d": "M12 9v4l2 2" }], ["path", { "d": "M5 3 2 6" }], ["path", { "d": "m22 6-3-3" }], ["path", { "d": "M6.38 18.7 4 21" }], ["path", { "d": "M17.64 18.67 20 21" }]], "bug": [["path", { "d": "M12 20v-9" }], ["path", { "d": "M14 7a4 4 0 0 1 4 4v3a6 6 0 0 1-12 0v-3a4 4 0 0 1 4-4z" }], ["path", { "d": "M14.12 3.88 16 2" }], ["path", { "d": "M21 21a4 4 0 0 0-3.81-4" }], ["path", { "d": "M21 5a4 4 0 0 1-3.55 3.97" }], ["path", { "d": "M22 13h-4" }], ["path", { "d": "M3 21a4 4 0 0 1 3.81-4" }], ["path", { "d": "M3 5a4 4 0 0 0 3.55 3.97" }], ["path", { "d": "M6 13H2" }], ["path", { "d": "m8 2 1.88 1.88" }], ["path", { "d": "M9 7.13V6a3 3 0 1 1 6 0v1.13" }]], "radio-tower": [["path", { "d": "M4.9 16.1C1 12.2 1 5.8 4.9 1.9" }], ["path", { "d": "M7.8 4.7a6.14 6.14 0 0 0-.8 7.5" }], ["circle", { "cx": "12", "cy": "9", "r": "2" }], ["path", { "d": "M16.2 4.8c2 2 2.26 5.11.8 7.47" }], ["path", { "d": "M19.1 1.9a9.96 9.96 0 0 1 0 14.1" }], ["path", { "d": "M9.5 18h5" }], ["path", { "d": "m8 22 4-11 4 11" }]], "app-window": [["rect", { "x": "2", "y": "4", "width": "20", "height": "16", "rx": "2" }], ["path", { "d": "M10 4v4" }], ["path", { "d": "M2 8h20" }], ["path", { "d": "M6 4v4" }]], "watch": [["path", { "d": "M12 10v2.2l1.6 1" }], ["path", { "d": "m16.13 7.66-.81-4.05a2 2 0 0 0-2-1.61h-2.68a2 2 0 0 0-2 1.61l-.78 4.05" }], ["path", { "d": "m7.88 16.36.8 4a2 2 0 0 0 2 1.61h2.72a2 2 0 0 0 2-1.61l.81-4.05" }], ["circle", { "cx": "12", "cy": "12", "r": "6" }]], "archive": [["rect", { "width": "20", "height": "5", "x": "2", "y": "3", "rx": "1" }], ["path", { "d": "M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8" }], ["path", { "d": "M10 12h4" }]], "rotate-cw": [["path", { "d": "M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8" }], ["path", { "d": "M21 3v5h-5" }]], "rotate-ccw": [["path", { "d": "M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" }], ["path", { "d": "M3 3v5h5" }]], "arrow-down": [["path", { "d": "M12 5v14" }], ["path", { "d": "m19 12-7 7-7-7" }]], "arrow-down-right": [["path", { "d": "m7 7 10 10" }], ["path", { "d": "M17 7v10H7" }]], "arrow-left": [["path", { "d": "m12 19-7-7 7-7" }], ["path", { "d": "M19 12H5" }]], "arrow-right": [["path", { "d": "M5 12h14" }], ["path", { "d": "m12 5 7 7-7 7" }]], "refresh-cw": [["path", { "d": "M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8" }], ["path", { "d": "M21 3v5h-5" }], ["path", { "d": "M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16" }], ["path", { "d": "M8 16H3v5" }]], "arrow-up": [["path", { "d": "m5 12 7-7 7 7" }], ["path", { "d": "M12 19V5" }]], "arrow-up-down": [["path", { "d": "m21 16-4 4-4-4" }], ["path", { "d": "M17 20V4" }], ["path", { "d": "m3 8 4-4 4 4" }], ["path", { "d": "M7 4v16" }]], "arrow-up-right": [["path", { "d": "M7 7h10v10" }], ["path", { "d": "M7 17 17 7" }]], "rewind": [["path", { "d": "M12 6a2 2 0 0 0-3.414-1.414l-6 6a2 2 0 0 0 0 2.828l6 6A2 2 0 0 0 12 18z" }], ["path", { "d": "M22 6a2 2 0 0 0-3.414-1.414l-6 6a2 2 0 0 0 0 2.828l6 6A2 2 0 0 0 22 18z" }]], "skip-back": [["path", { "d": "M17.971 4.285A2 2 0 0 1 21 6v12a2 2 0 0 1-3.029 1.715l-9.997-5.998a2 2 0 0 1-.003-3.432z" }], ["path", { "d": "M3 20V4" }]], "shopping-bag": [["path", { "d": "M16 10a4 4 0 0 1-8 0" }], ["path", { "d": "M3.103 6.034h17.794" }], ["path", { "d": "M3.4 5.467a2 2 0 0 0-.4 1.2V20a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V6.667a2 2 0 0 0-.4-1.2l-2-2.667A2 2 0 0 0 17 2H7a2 2 0 0 0-1.6.8z" }]], "banknote": [["rect", { "width": "20", "height": "12", "x": "2", "y": "6", "rx": "2" }], ["circle", { "cx": "12", "cy": "12", "r": "2" }], ["path", { "d": "M6 12h.01M18 12h.01" }]], "battery": [["path", { "d": "M 22 14 L 22 10" }], ["rect", { "x": "2", "y": "6", "width": "16", "height": "12", "rx": "2" }]], "battery-full": [["path", { "d": "M10 10v4" }], ["path", { "d": "M14 10v4" }], ["path", { "d": "M22 14v-4" }], ["path", { "d": "M6 10v4" }], ["rect", { "x": "2", "y": "6", "width": "16", "height": "12", "rx": "2" }]], "battery-charging": [["path", { "d": "m11 7-3 5h4l-3 5" }], ["path", { "d": "M14.856 6H16a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-2.935" }], ["path", { "d": "M22 14v-4" }], ["path", { "d": "M5.14 18H4a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h2.936" }]], "battery-low": [["path", { "d": "M22 14v-4" }], ["path", { "d": "M6 14v-4" }], ["rect", { "x": "2", "y": "6", "width": "16", "height": "12", "rx": "2" }]], "battery-medium": [["path", { "d": "M10 14v-4" }], ["path", { "d": "M22 14v-4" }], ["path", { "d": "M6 14v-4" }], ["rect", { "x": "2", "y": "6", "width": "16", "height": "12", "rx": "2" }]], "bed": [["path", { "d": "M2 4v16" }], ["path", { "d": "M2 8h18a2 2 0 0 1 2 2v10" }], ["path", { "d": "M2 17h20" }], ["path", { "d": "M6 8v9" }]], "bed-double": [["path", { "d": "M2 20v-8a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v8" }], ["path", { "d": "M4 10V6a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v4" }], ["path", { "d": "M12 4v6" }], ["path", { "d": "M2 18h20" }]], "bell": [["path", { "d": "M10.268 21a2 2 0 0 0 3.464 0" }], ["path", { "d": "M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326" }]], "bell-dot": [["path", { "d": "M10.268 21a2 2 0 0 0 3.464 0" }], ["path", { "d": "M11.68 2.009A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673c-.824-.85-1.678-1.731-2.21-3.348" }], ["circle", { "cx": "18", "cy": "5", "r": "3" }]], "bell-off": [["path", { "d": "M10.268 21a2 2 0 0 0 3.464 0" }], ["path", { "d": "M17 17H4a1 1 0 0 1-.74-1.673C4.59 13.956 6 12.499 6 8a6 6 0 0 1 .258-1.742" }], ["path", { "d": "m2 2 20 20" }], ["path", { "d": "M8.668 3.01A6 6 0 0 1 18 8c0 2.687.77 4.653 1.707 6.05" }]], "bike": [["circle", { "cx": "18.5", "cy": "17.5", "r": "3.5" }], ["circle", { "cx": "5.5", "cy": "17.5", "r": "3.5" }], ["circle", { "cx": "15", "cy": "5", "r": "1" }], ["path", { "d": "M12 17.5V14l-3-3 4-3 2 3h2" }]], "bird": [["path", { "d": "M16 7h.01" }], ["path", { "d": "M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20" }], ["path", { "d": "m20 7 2 .5-2 .5" }], ["path", { "d": "M10 18v3" }], ["path", { "d": "M14 17.75V21" }], ["path", { "d": "M7 18a6 6 0 0 0 3.84-10.61" }]], "cake": [["path", { "d": "M20 21v-8a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8" }], ["path", { "d": "M4 16s.5-1 2-1 2.5 2 4 2 2.5-2 4-2 2.5 2 4 2 2-1 2-1" }], ["path", { "d": "M2 21h20" }], ["path", { "d": "M7 8v3" }], ["path", { "d": "M12 8v3" }], ["path", { "d": "M17 8v3" }], ["path", { "d": "M7 4h.01" }], ["path", { "d": "M12 4h.01" }], ["path", { "d": "M17 4h.01" }]], "zap": [["path", { "d": "M15.914 4a1.5 1.5 0 00-2.474-1.561l-9 9A1.5 1.5 0 005.5 14h4.002a.5.5 0 01.471.666L8.086 20a1.5 1.5 0 002.475 1.56l9-9A1.5 1.5 0 0018.5 10h-3.997a.5.5 0 01-.472-.667z" }]], "car": [["path", { "d": "M19 17h2c.6 0 1-.4 1-1v-3c0-.9-.7-1.7-1.5-1.9C18.7 10.6 16 10 16 10s-1.3-1.4-2.2-2.3c-.5-.4-1.1-.7-1.8-.7H5c-.6 0-1.1.4-1.4.9l-1.4 2.9A3.7 3.7 0 0 0 2 12v4c0 .6.4 1 1 1h2" }], ["circle", { "cx": "7", "cy": "17", "r": "2" }], ["path", { "d": "M9 17h6" }], ["circle", { "cx": "17", "cy": "17", "r": "2" }]], "heart-pulse": [["path", { "d": "M2 9.5a5.5 5.5 0 0 1 9.591-3.676.56.56 0 0 0 .818 0A5.49 5.49 0 0 1 22 9.5c0 2.29-1.5 4-3 5.5l-5.492 5.313a2 2 0 0 1-3 .019L5 15c-1.5-1.5-3-3.2-3-5.5" }], ["path", { "d": "M3.22 13H9.5l.5-1 2 4.5 2-7 1.5 3.5h5.27" }]], "radio": [["path", { "d": "M16.247 7.761a6 6 0 0 1 0 8.478" }], ["path", { "d": "M19.075 4.933a10 10 0 0 1 0 14.134" }], ["path", { "d": "M4.925 19.067a10 10 0 0 1 0-14.134" }], ["path", { "d": "M7.753 16.239a6 6 0 0 1 0-8.478" }], ["circle", { "cx": "12", "cy": "12", "r": "2" }]], "book": [["path", { "d": "M4 19.5v-15A2.5 2.5 0 0 1 6.5 2H19a1 1 0 0 1 1 1v18a1 1 0 0 1-1 1H6.5a1 1 0 0 1 0-5H20" }]], "bookmark": [["path", { "d": "M17 3a2 2 0 0 1 2 2v15a1 1 0 0 1-1.496.868l-4.512-2.578a2 2 0 0 0-1.984 0l-4.512 2.578A1 1 0 0 1 5 20V5a2 2 0 0 1 2-2z" }]], "library": [["path", { "d": "m16 6 4 14" }], ["path", { "d": "M12 6v14" }], ["path", { "d": "M8 8v12" }], ["path", { "d": "M4 4v16" }]], "brain": [["path", { "d": "M12 18V5" }], ["path", { "d": "M15 13a4.17 4.17 0 0 1-3-4 4.17 4.17 0 0 1-3 4" }], ["path", { "d": "M17.598 6.5A3 3 0 1 0 12 5a3 3 0 1 0-5.598 1.5" }], ["path", { "d": "M17.997 5.125a4 4 0 0 1 2.526 5.77" }], ["path", { "d": "M18 18a4 4 0 0 0 2-7.464" }], ["path", { "d": "M19.967 17.483A4 4 0 1 1 12 18a4 4 0 1 1-7.967-.517" }], ["path", { "d": "M6 18a4 4 0 0 1-2-7.464" }], ["path", { "d": "M6.003 5.125a4 4 0 0 0-2.526 5.77" }]], "briefcase": [["path", { "d": "M16 20V4a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16" }], ["rect", { "width": "20", "height": "14", "x": "2", "y": "6", "rx": "2" }]], "message-circle": [["path", { "d": "M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719" }]], "messages-square": [["path", { "d": "M16 10a2 2 0 0 1-2 2H6.828a2 2 0 0 0-1.414.586l-2.202 2.202A.71.71 0 0 1 2 14.286V4a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2z" }], ["path", { "d": "M20 9a2 2 0 0 1 2 2v10.286a.71.71 0 0 1-1.212.502l-2.202-2.202A2 2 0 0 0 17.172 19H10a2 2 0 0 1-2-2v-1" }]], "building": [["path", { "d": "M12 10h.01" }], ["path", { "d": "M12 14h.01" }], ["path", { "d": "M12 6h.01" }], ["path", { "d": "M16 10h.01" }], ["path", { "d": "M16 14h.01" }], ["path", { "d": "M16 6h.01" }], ["path", { "d": "M8 10h.01" }], ["path", { "d": "M8 14h.01" }], ["path", { "d": "M8 6h.01" }], ["path", { "d": "M9 22v-3a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v3" }], ["rect", { "x": "4", "y": "2", "width": "16", "height": "20", "rx": "2" }]], "landmark": [["path", { "d": "M10 18v-7" }], ["path", { "d": "M11.119 2.205a2 2 0 0 1 1.762 0l7.84 3.846A.5.5 0 0 1 20.5 7h-17a.5.5 0 0 1-.22-.949z" }], ["path", { "d": "M14 18v-7" }], ["path", { "d": "M18 18v-7" }], ["path", { "d": "M3 22h18" }], ["path", { "d": "M6 18v-7" }]], "bus": [["path", { "d": "M8 6v6" }], ["path", { "d": "M15 6v6" }], ["path", { "d": "M2 12h19.6" }], ["path", { "d": "M18 18h3s.5-1.7.8-2.8c.1-.4.2-.8.2-1.2 0-.4-.1-.8-.2-1.2l-1.4-5C20.1 6.8 19.1 6 18 6H4a2 2 0 0 0-2 2v10h3" }], ["circle", { "cx": "7", "cy": "18", "r": "2" }], ["path", { "d": "M9 18h5" }], ["circle", { "cx": "16", "cy": "18", "r": "2" }]], "calendar": [["path", { "d": "M8 2v3" }], ["path", { "d": "M16 2v3" }], ["rect", { "x": "3", "y": "3", "width": "18", "height": "18", "rx": "2" }], ["path", { "d": "M3 9h18" }]], "calendar-clock": [["path", { "d": "M16 14v2.2l1.6 1" }], ["path", { "d": "M16 2v3" }], ["path", { "d": "M21 7.338V5a2 2 0 00-2-2H5a2 2 0 00-2 2v14a2 2 0 002 2h2.338" }], ["path", { "d": "M3 9h5.859" }], ["path", { "d": "M8 2v3" }], ["circle", { "cx": "16", "cy": "16", "r": "6" }]], "calendar-x": [["path", { "d": "M8 2v3" }], ["path", { "d": "M16 2v3" }], ["rect", { "x": "3", "y": "3", "width": "18", "height": "18", "rx": "2" }], ["path", { "d": "M3 9h18" }], ["path", { "d": "m14 13-4 4" }], ["path", { "d": "m10 13 4 4" }]], "calendar-plus": [["path", { "d": "M16 18h6" }], ["path", { "d": "M16 2v3" }], ["path", { "d": "M19 15v6" }], ["path", { "d": "M21 11.5V5a2 2 0 00-2-2H5a2 2 0 00-2 2v14a2 2 0 002 2h8.3" }], ["path", { "d": "M3 9h18" }], ["path", { "d": "M8 2v3" }]], "camera": [["path", { "d": "M13.997 4a2 2 0 0 1 1.76 1.05l.486.9A2 2 0 0 0 18.003 7H20a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2h1.997a2 2 0 0 0 1.759-1.048l.489-.904A2 2 0 0 1 10.004 4z" }], ["circle", { "cx": "12", "cy": "13", "r": "3" }]], "flower": [["circle", { "cx": "12", "cy": "12", "r": "3" }], ["path", { "d": "M12 16.5A4.5 4.5 0 1 1 7.5 12 4.5 4.5 0 1 1 12 7.5a4.5 4.5 0 1 1 4.5 4.5 4.5 4.5 0 1 1-4.5 4.5" }], ["path", { "d": "M12 7.5V9" }], ["path", { "d": "M7.5 12H9" }], ["path", { "d": "M16.5 12H15" }], ["path", { "d": "M12 16.5V15" }], ["path", { "d": "m8 8 1.88 1.88" }], ["path", { "d": "M14.12 9.88 16 8" }], ["path", { "d": "m8 16 1.88-1.88" }], ["path", { "d": "M14.12 14.12 16 16" }]], "carrot": [["path", { "d": "M15 16a1 1 0 0 0-7-7q-4 4-5.987 12.385a.5.5 0 0 0 .602.602Q11 20 15 16l-3-3" }], ["path", { "d": "M15 9q4 4 7 0-3-4-7 0 4-4 0-7-4 3 0 7" }], ["path", { "d": "m8 15-2.58-2.58" }]], "shopping-cart": [["path", { "d": "m2.05 2.05 1.099-.028a1 1 0 0 1 1.008.815l2.69 14.347A1 1 0 0 0 7.83 18H18" }], ["path", { "d": "M4.563 5h16.435a1 1 0 0 1 .981 1.204l-1.026 6.226A2 2 0 0 1 18.962 14H6.25" }], ["circle", { "cx": "18", "cy": "20", "r": "2" }], ["circle", { "cx": "8", "cy": "20", "r": "2" }]], "chart-column": [["path", { "d": "M3 3v16a2 2 0 0 0 2 2h16" }], ["path", { "d": "M18 17V9" }], ["path", { "d": "M13 17V5" }], ["path", { "d": "M8 17v-3" }]], "chart-line": [["path", { "d": "M3 3v16a2 2 0 0 0 2 2h16" }], ["path", { "d": "m19 9-5 5-4-4-3 3" }]], "chart-pie": [["path", { "d": "M21 12c.552 0 1.005-.449.95-.998a10 10 0 0 0-8.953-8.951c-.55-.055-.998.398-.998.95v8a1 1 0 0 0 1 1z" }], ["path", { "d": "M21.21 15.89A10 10 0 1 1 8 2.83" }]], "list-checks": [["path", { "d": "M13 5h8" }], ["path", { "d": "M13 12h8" }], ["path", { "d": "M13 19h8" }], ["path", { "d": "m3 17 2 2 4-4" }], ["path", { "d": "m3 7 2 2 4-4" }]], "check": [["path", { "d": "M20 6 9 17l-5-5" }]], "circle-check": [["circle", { "cx": "12", "cy": "12", "r": "10" }], ["path", { "d": "m16 9-5.5 5.5L8 12" }]], "badge-check": [["path", { "d": "M3.85 8.62a4 4 0 0 1 4.78-4.77 4 4 0 0 1 6.74 0 4 4 0 0 1 4.78 4.78 4 4 0 0 1 0 6.74 4 4 0 0 1-4.77 4.78 4 4 0 0 1-6.75 0 4 4 0 0 1-4.78-4.77 4 4 0 0 1 0-6.76Z" }], ["path", { "d": "m16 9-5.5 5.5L8 12" }]], "square-check": [["rect", { "width": "18", "height": "18", "x": "3", "y": "3", "rx": "2" }], ["path", { "d": "m16 9-5.5 5.5L8 12" }]], "chevron-down": [["path", { "d": "m6 9 6 6 6-6" }]], "chevron-left": [["path", { "d": "m15 18-6-6 6-6" }]], "code-xml": [["path", { "d": "m18 16 4-4-4-4" }], ["path", { "d": "m6 8-4 4 4 4" }], ["path", { "d": "m14.5 4-5 16" }]], "chevron-right": [["path", { "d": "m9 18 6-6-6-6" }]], "chevron-up": [["path", { "d": "m18 15-6-6-6 6" }]], "circle": [["circle", { "cx": "12", "cy": "12", "r": "10" }]], "grid-2x2": [["path", { "d": "M12 3v18" }], ["path", { "d": "M3 12h18" }], ["rect", { "x": "3", "y": "3", "width": "18", "height": "18", "rx": "2" }]], "clock": [["circle", { "cx": "12", "cy": "12", "r": "10" }], ["path", { "d": "M12 6v6l4 2" }]], "rotate-ccw-clock": [["path", { "d": "M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" }], ["path", { "d": "M3 3v5h5" }], ["path", { "d": "M12 7v5l4 2" }]], "cloud": [["path", { "d": "M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z" }]], "cloud-lightning": [["path", { "d": "M6 16.326A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 .5 8.973" }], ["path", { "d": "m13 12-3 5h4l-3 5" }]], "cloud-drizzle": [["path", { "d": "M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242" }], ["path", { "d": "M8 19v1" }], ["path", { "d": "M8 14v1" }], ["path", { "d": "M16 19v1" }], ["path", { "d": "M16 14v1" }], ["path", { "d": "M12 21v1" }], ["path", { "d": "M12 16v1" }]], "cloud-fog": [["path", { "d": "M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242" }], ["path", { "d": "M16 17H7" }], ["path", { "d": "M17 21H9" }]], "cloud-moon": [["path", { "d": "M13 16a3 3 0 0 1 0 6H7a5 5 0 1 1 4.9-6z" }], ["path", { "d": "M18.376 14.512a6 6 0 0 0 3.461-4.127c.148-.625-.659-.97-1.248-.714a4 4 0 0 1-5.259-5.26c.255-.589-.09-1.395-.716-1.248a6 6 0 0 0-4.594 5.36" }]], "cloud-rain": [["path", { "d": "M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242" }], ["path", { "d": "M16 14v6" }], ["path", { "d": "M8 14v6" }], ["path", { "d": "M12 16v6" }]], "cloud-snow": [["path", { "d": "M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242" }], ["path", { "d": "M8 15h.01" }], ["path", { "d": "M8 19h.01" }], ["path", { "d": "M12 17h.01" }], ["path", { "d": "M12 21h.01" }], ["path", { "d": "M16 15h.01" }], ["path", { "d": "M16 19h.01" }]], "cloud-sun": [["path", { "d": "M12 2v2" }], ["path", { "d": "m4.93 4.93 1.41 1.41" }], ["path", { "d": "M20 12h2" }], ["path", { "d": "m19.07 4.93-1.41 1.41" }], ["path", { "d": "M15.947 12.65a4 4 0 0 0-5.925-4.128" }], ["path", { "d": "M13 22H7a5 5 0 1 1 4.9-6H13a3 3 0 0 1 0 6Z" }]], "cloud-sun-rain": [["path", { "d": "M12 2v2" }], ["path", { "d": "m4.93 4.93 1.41 1.41" }], ["path", { "d": "M20 12h2" }], ["path", { "d": "m19.07 4.93-1.41 1.41" }], ["path", { "d": "M15.947 12.65a4 4 0 0 0-5.925-4.128" }], ["path", { "d": "M3 20a5 5 0 1 1 8.9-4H13a3 3 0 0 1 2 5.24" }], ["path", { "d": "M11 20v2" }], ["path", { "d": "M7 19v2" }]], "cpu": [["path", { "d": "M12 20v2" }], ["path", { "d": "M12 2v2" }], ["path", { "d": "M17 20v2" }], ["path", { "d": "M17 2v2" }], ["path", { "d": "M2 12h2" }], ["path", { "d": "M2 17h2" }], ["path", { "d": "M2 7h2" }], ["path", { "d": "M20 12h2" }], ["path", { "d": "M20 17h2" }], ["path", { "d": "M20 7h2" }], ["path", { "d": "M7 20v2" }], ["path", { "d": "M7 2v2" }], ["rect", { "x": "4", "y": "4", "width": "16", "height": "16", "rx": "2" }], ["rect", { "x": "8", "y": "8", "width": "8", "height": "8", "rx": "1" }]], "credit-card": [["rect", { "width": "20", "height": "14", "x": "2", "y": "5", "rx": "2" }], ["line", { "x1": "2", "x2": "22", "y1": "10", "y2": "10" }], ["path", { "d": "M6 14h2" }]], "cross": [["path", { "d": "M4 9a2 2 0 0 0-2 2v2a2 2 0 0 0 2 2h4a1 1 0 0 1 1 1v4a2 2 0 0 0 2 2h2a2 2 0 0 0 2-2v-4a1 1 0 0 1 1-1h4a2 2 0 0 0 2-2v-2a2 2 0 0 0-2-2h-4a1 1 0 0 1-1-1V4a2 2 0 0 0-2-2h-2a2 2 0 0 0-2 2v4a1 1 0 0 1-1 1z" }]], "crown": [["path", { "d": "M11.562 3.266a.5.5 0 0 1 .876 0L15.39 8.87a1 1 0 0 0 1.516.294L21.183 5.5a.5.5 0 0 1 .798.519l-2.834 10.246a1 1 0 0 1-.956.734H5.81a1 1 0 0 1-.957-.734L2.02 6.02a.5.5 0 0 1 .798-.519l4.276 3.664a1 1 0 0 0 1.516-.294z" }], ["path", { "d": "M5 21h14" }]], "cup-soda": [["path", { "d": "m6 8 1.75 12.28a2 2 0 0 0 2 1.72h4.54a2 2 0 0 0 2-1.72L18 8" }], ["path", { "d": "M5 8h14" }], ["path", { "d": "M7 15a6.47 6.47 0 0 1 5 0 6.47 6.47 0 0 0 5 0" }], ["path", { "d": "m12 8 1-6h2" }]], "coffee": [["path", { "d": "M10 2v2" }], ["path", { "d": "M14 2v2" }], ["path", { "d": "M16 8a1 1 0 0 1 1 1v8a4 4 0 0 1-4 4H7a4 4 0 0 1-4-4V9a1 1 0 0 1 1-1h14a4 4 0 1 1 0 8h-1" }], ["path", { "d": "M6 2v2" }]], "monitor": [["rect", { "width": "20", "height": "14", "x": "2", "y": "3", "rx": "2" }], ["line", { "x1": "8", "x2": "16", "y1": "21", "y2": "21" }], ["line", { "x1": "12", "x2": "12", "y1": "17", "y2": "21" }]], "dices": [["rect", { "width": "12", "height": "12", "x": "2", "y": "10", "rx": "2", "ry": "2" }], ["path", { "d": "m17.92 14 3.5-3.5a2.24 2.24 0 0 0 0-3l-5-4.92a2.24 2.24 0 0 0-3 0L10 6" }], ["path", { "d": "M6 18h.01" }], ["path", { "d": "M10 14h.01" }], ["path", { "d": "M15 6h.01" }], ["path", { "d": "M18 9h.01" }]], "file": [["path", { "d": "M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z" }], ["path", { "d": "M14 2v5a1 1 0 0 0 1 1h5" }]], "file-text": [["path", { "d": "M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z" }], ["path", { "d": "M14 2v5a1 1 0 0 0 1 1h5" }], ["path", { "d": "M10 9H8" }], ["path", { "d": "M16 13H8" }], ["path", { "d": "M16 17H8" }]], "circle-dollar-sign": [["circle", { "cx": "12", "cy": "12", "r": "10" }], ["path", { "d": "M16 8h-6a2 2 0 1 0 0 4h4a2 2 0 1 1 0 4H8" }], ["path", { "d": "M12 18V6" }]], "droplet": [["path", { "d": "M12 22a7 7 0 0 0 7-7c0-2-1-3.9-3-5.5s-3.5-4-4-6.5c-.5 2.5-2 4.9-4 6.5C6 11.1 5 13 5 15a7 7 0 0 0 7 7z" }]], "thermometer": [["path", { "d": "M14 4v10.54a4 4 0 1 1-4 0V4a2 2 0 0 1 4 0Z" }]], "dumbbell": [["path", { "d": "M17.596 12.768a2 2 0 1 0 2.829-2.829l-1.768-1.767a2 2 0 0 0 2.828-2.829l-2.828-2.828a2 2 0 0 0-2.829 2.828l-1.767-1.768a2 2 0 1 0-2.829 2.829z" }], ["path", { "d": "m2.5 21.5 1.4-1.4" }], ["path", { "d": "m20.1 3.9 1.4-1.4" }], ["path", { "d": "M5.343 21.485a2 2 0 1 0 2.829-2.828l1.767 1.768a2 2 0 1 0 2.829-2.829l-6.364-6.364a2 2 0 1 0-2.829 2.829l1.768 1.767a2 2 0 0 0-2.828 2.829z" }], ["path", { "d": "m9.6 14.4 4.8-4.8" }]], "ellipsis": [["circle", { "cx": "12", "cy": "12", "r": "1" }], ["circle", { "cx": "19", "cy": "12", "r": "1" }], ["circle", { "cx": "5", "cy": "12", "r": "1" }]], "circle-ellipsis": [["circle", { "cx": "12", "cy": "12", "r": "10" }], ["path", { "d": "M17 12h.01" }], ["path", { "d": "M12 12h.01" }], ["path", { "d": "M7 12h.01" }]], "mail": [["path", { "d": "m22 7-8.991 5.727a2 2 0 0 1-2.009 0L2 7" }], ["rect", { "x": "2", "y": "4", "width": "20", "height": "16", "rx": "2" }]], "mail-open": [["path", { "d": "M21.2 8.4c.5.38.8.97.8 1.6v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V10a2 2 0 0 1 .8-1.6l8-6a2 2 0 0 1 2.4 0l8 6Z" }], ["path", { "d": "m22 10-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 10" }]], "circle-alert": [["circle", { "cx": "12", "cy": "12", "r": "10" }], ["line", { "x1": "12", "x2": "12", "y1": "8", "y2": "12" }], ["line", { "x1": "12", "x2": "12.01", "y1": "16", "y2": "16" }]], "triangle-alert": [["path", { "d": "m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3" }], ["path", { "d": "M12 9v4" }], ["path", { "d": "M12 17h.01" }]], "eye": [["path", { "d": "M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0" }], ["circle", { "cx": "12", "cy": "12", "r": "3" }]], "eye-off": [["path", { "d": "M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 10.747 10.747 0 0 1-1.444 2.49" }], ["path", { "d": "M14.084 14.158a3 3 0 0 1-4.242-4.242" }], ["path", { "d": "M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 0-.696 10.75 10.75 0 0 1 4.446-5.143" }], ["path", { "d": "m2 2 20 20" }]], "pipette": [["path", { "d": "m12 9-8.414 8.414A2 2 0 0 0 3 18.828v1.344a2 2 0 0 1-.586 1.414A2 2 0 0 1 3.828 21h1.344a2 2 0 0 0 1.414-.586L15 12" }], ["path", { "d": "m18 9 .4.4a1 1 0 1 1-3 3l-3.8-3.8a1 1 0 1 1 3-3l.4.4 3.4-3.4a1 1 0 1 1 3 3z" }], ["path", { "d": "m2 22 .414-.414" }]], "face-slightly-smiling": [["path", { "d": "M15 10V9" }], ["path", { "d": "M16.472 15a6 6 0 01-8.943 0" }], ["path", { "d": "M9 10V9" }], ["circle", { "cx": "12", "cy": "12", "r": "10" }]], "scan-face": [["path", { "d": "M3 7V5a2 2 0 0 1 2-2h2" }], ["path", { "d": "M17 3h2a2 2 0 0 1 2 2v2" }], ["path", { "d": "M21 17v2a2 2 0 0 1-2 2h-2" }], ["path", { "d": "M7 21H5a2 2 0 0 1-2-2v-2" }], ["path", { "d": "M8 14s1.5 2 4 2 4-2 4-2" }], ["path", { "d": "M9 9h.01" }], ["path", { "d": "M15 9h.01" }]], "ship": [["path", { "d": "M12 2v2" }], ["path", { "d": "M12 9.189V13" }], ["path", { "d": "M19 12V6a2 2 0 00-2-2H7a2 2 0 00-2 2v6" }], ["path", { "d": "M19.38 19A11.6 11.6 0 0021 13l-8.188-3.639a2 2 0 00-1.624 0L3 13.001a11.6 11.6 0 002.81 7.76" }], ["path", { "d": "M2 20c.6.5 1.2 1 2.5 1 2.5 0 2.5-2 5-2 1.3 0 1.9.5 2.5 1s1.2 1 2.5 1c2.5 0 2.5-2 5-2 1.3 0 1.9.5 2.5 1" }]], "flower-2": [["path", { "d": "M12 5a3 3 0 1 1 3 3m-3-3a3 3 0 1 0-3 3m3-3v1M9 8a3 3 0 1 0 3 3M9 8h1m5 0a3 3 0 1 1-3 3m3-3h-1m-2 3v-1" }], ["circle", { "cx": "12", "cy": "8", "r": "2" }], ["path", { "d": "M12 10v12" }], ["path", { "d": "M12 22c4.2 0 7-1.667 7-5-4.2 0-7 1.667-7 5Z" }], ["path", { "d": "M12 22c-4.2 0-7-1.667-7-5 4.2 0 7 1.667 7 5Z" }]], "footprints": [["path", { "d": "M4 16v-2.38C4 11.5 2.97 10.5 3 8c.03-2.72 1.49-6 4.5-6C9.37 2 10 3.8 10 5.5c0 3.11-2 5.66-2 8.68V16a2 2 0 1 1-4 0Z" }], ["path", { "d": "M20 20v-2.38c0-2.12 1.03-3.12 1-5.62-.03-2.72-1.49-6-4.5-6C14.63 6 14 7.8 14 9.5c0 3.11 2 5.66 2 8.68V20a2 2 0 1 0 4 0Z" }], ["path", { "d": "M16 17h4" }], ["path", { "d": "M4 13h4" }]], "film": [["rect", { "width": "18", "height": "18", "x": "3", "y": "3", "rx": "2" }], ["path", { "d": "M7 3v18" }], ["path", { "d": "M3 7.5h4" }], ["path", { "d": "M3 12h18" }], ["path", { "d": "M3 16.5h4" }], ["path", { "d": "M17 3v18" }], ["path", { "d": "M17 7.5h4" }], ["path", { "d": "M17 16.5h4" }]], "fish": [["path", { "d": "M6.5 12c.94-3.46 4.94-6 8.5-6 3.56 0 6.06 2.54 7 6-.94 3.47-3.44 6-7 6s-7.56-2.53-8.5-6Z" }], ["path", { "d": "M18 12v.5" }], ["path", { "d": "M16 17.93a9.77 9.77 0 0 1 0-11.86" }], ["path", { "d": "M7 10.67C7 8 5.58 5.97 2.73 5.5c-1 1.5-1 5 .23 6.5-1.24 1.5-1.24 5-.23 6.5C5.58 18.03 7 16 7 13.33" }], ["path", { "d": "M10.46 7.26C10.2 5.88 9.17 4.24 8 3h5.8a2 2 0 0 1 1.98 1.67l.23 1.4" }], ["path", { "d": "m16.01 17.93-.23 1.4A2 2 0 0 1 13.8 21H9.5a5.96 5.96 0 0 0 1.49-3.98" }]], "flag": [["path", { "d": "M4 22V4a1 1 0 0 1 .4-.8A6 6 0 0 1 8 2c3 0 5 2 7.333 2q2 0 3.067-.8A1 1 0 0 1 20 4v10a1 1 0 0 1-.4.8A6 6 0 0 1 16 16c-3 0-5-2-8-2a6 6 0 0 0-4 1.528" }]], "flame": [["path", { "d": "M12 3q1 4 4 6.5t3 5.5a1 1 0 0 1-14 0 5 5 0 0 1 1-3 1 1 0 0 0 5 0c0-2-1.5-3-1.5-5q0-2 2.5-4" }]], "folder": [["path", { "d": "M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z" }]], "utensils": [["path", { "d": "M3 2v7c0 1.1.9 2 2 2h4a2 2 0 0 0 2-2V2" }], ["path", { "d": "M7 2v20" }], ["path", { "d": "M21 15V2a5 5 0 0 0-5 5v6c0 1.1.9 2 2 2h3Zm0 0v7" }]], "fast-forward": [["path", { "d": "M12 6a2 2 0 0 1 3.414-1.414l6 6a2 2 0 0 1 0 2.828l-6 6A2 2 0 0 1 12 18z" }], ["path", { "d": "M2 6a2 2 0 0 1 3.414-1.414l6 6a2 2 0 0 1 0 2.828l-6 6A2 2 0 0 1 2 18z" }]], "skip-forward": [["path", { "d": "M21 4v16" }], ["path", { "d": "M6.029 4.285A2 2 0 0 0 3 6v12a2 2 0 0 0 3.029 1.715l9.997-5.998a2 2 0 0 0 .003-3.432z" }]], "fuel": [["path", { "d": "M14 13h2a2 2 0 0 1 2 2v2a2 2 0 0 0 4 0v-6.998a2 2 0 0 0-.59-1.42L18 5" }], ["path", { "d": "M14 21V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v16" }], ["path", { "d": "M2 21h13" }], ["path", { "d": "M3 9h11" }]], "gamepad-2": [["line", { "x1": "6", "x2": "10", "y1": "11", "y2": "11" }], ["line", { "x1": "8", "x2": "8", "y1": "9", "y2": "13" }], ["line", { "x1": "15", "x2": "15.01", "y1": "12", "y2": "12" }], ["line", { "x1": "18", "x2": "18.01", "y1": "10", "y2": "10" }], ["path", { "d": "M17.32 5H6.68a4 4 0 0 0-3.978 3.59c-.006.052-.01.101-.017.152C2.604 9.416 2 14.456 2 16a3 3 0 0 0 3 3c1 0 1.5-.5 2-1l1.414-1.414A2 2 0 0 1 9.828 16h4.344a2 2 0 0 1 1.414.586L17 18c.5.5 1 1 2 1a3 3 0 0 0 3-3c0-1.545-.604-6.584-.685-7.258-.007-.05-.011-.1-.017-.151A4 4 0 0 0 17.32 5z" }]], "gauge": [["path", { "d": "m12 14 4-4" }], ["path", { "d": "M3.34 19a10 10 0 1 1 17.32 0" }]], "settings": [["path", { "d": "M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915" }], ["circle", { "cx": "12", "cy": "12", "r": "3" }]], "gift": [["path", { "d": "M12 7v14" }], ["path", { "d": "M20 11v8a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-8" }], ["path", { "d": "M7.5 7a1 1 0 0 1 0-5A4.8 8 0 0 1 12 7a4.8 8 0 0 1 4.5-5 1 1 0 0 1 0 5" }], ["rect", { "x": "3", "y": "7", "width": "18", "height": "4", "rx": "1" }]], "globe": [["circle", { "cx": "12", "cy": "12", "r": "10" }], ["path", { "d": "M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20" }], ["path", { "d": "M2 12h20" }]], "earth": [["path", { "d": "M21.54 15H17a2 2 0 0 0-2 2v4.54" }], ["path", { "d": "M7 3.34V5a3 3 0 0 0 3 3a2 2 0 0 1 2 2c0 1.1.9 2 2 2a2 2 0 0 0 2-2c0-1.1.9-2 2-2h3.17" }], ["path", { "d": "M11 21.95V18a2 2 0 0 0-2-2a2 2 0 0 1-2-2v-1a2 2 0 0 0-2-2H2.05" }], ["circle", { "cx": "12", "cy": "12", "r": "10" }]], "graduation-cap": [["path", { "d": "M21.42 10.922a1 1 0 0 0-.019-1.838L12.83 5.18a2 2 0 0 0-1.66 0L2.6 9.08a1 1 0 0 0 0 1.832l8.57 3.908a2 2 0 0 0 1.66 0z" }], ["path", { "d": "M22 10v6" }], ["path", { "d": "M6 12.5V16a6 3 0 0 0 12 0v-3.5" }]], "guitar": [["path", { "d": "m11.9 12.1 4.514-4.514" }], ["path", { "d": "M20.1 2.3a1 1 0 0 0-1.4 0l-1.114 1.114A2 2 0 0 0 17 4.828v1.344a2 2 0 0 1-.586 1.414A2 2 0 0 1 17.828 7h1.344a2 2 0 0 0 1.414-.586L21.7 5.3a1 1 0 0 0 0-1.4z" }], ["path", { "d": "m6 16 2 2" }], ["path", { "d": "M8.23 9.85A3 3 0 0 1 11 8a5 5 0 0 1 5 5 3 3 0 0 1-1.85 2.77l-.92.38A2 2 0 0 0 12 18a4 4 0 0 1-4 4 6 6 0 0 1-6-6 4 4 0 0 1 4-4 2 2 0 0 0 1.85-1.23z" }]], "hammer": [["path", { "d": "m15 12-9.373 9.373a1 1 0 0 1-3.001-3L12 9" }], ["path", { "d": "m18 15 4-4" }], ["path", { "d": "m21.5 11.5-1.914-1.914A2 2 0 0 1 19 8.172v-.344a2 2 0 0 0-.586-1.414l-1.657-1.657A6 6 0 0 0 12.516 3H9l1.243 1.243A6 6 0 0 1 12 8.485V10l2 2h1.172a2 2 0 0 1 1.414.586L18.5 14.5" }]], "hand": [["path", { "d": "M18 11V6a2 2 0 0 0-2-2a2 2 0 0 0-2 2" }], ["path", { "d": "M14 10V4a2 2 0 0 0-2-2a2 2 0 0 0-2 2v2" }], ["path", { "d": "M10 10.5V6a2 2 0 0 0-2-2a2 2 0 0 0-2 2v8" }], ["path", { "d": "M18 8a2 2 0 1 1 4 0v6a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15" }]], "thumbs-up": [["path", { "d": "M15 5.88 14 10h5.83a2 2 0 0 1 1.92 2.56l-2.33 8A2 2 0 0 1 17.5 22H4a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2h2.76a2 2 0 0 0 1.79-1.11L12 2a3.13 3.13 0 0 1 3 3.88Z" }], ["path", { "d": "M7 10v12" }]], "party-popper": [["path", { "d": "M5.8 11.3 2 22l10.7-3.79" }], ["path", { "d": "M4 3h.01" }], ["path", { "d": "M22 8h.01" }], ["path", { "d": "M15 2h.01" }], ["path", { "d": "M22 20h.01" }], ["path", { "d": "m22 2-2.24.75a2.9 2.9 0 0 0-1.96 3.12c.1.86-.57 1.63-1.45 1.63h-.38c-.86 0-1.6.6-1.76 1.44L14 10" }], ["path", { "d": "m22 13-.82-.33c-.86-.34-1.82.2-1.98 1.11c-.11.7-.72 1.22-1.43 1.22H17" }], ["path", { "d": "m11 2 .33.82c.34.86-.2 1.82-1.11 1.98C9.52 4.9 9 5.52 9 6.23V7" }], ["path", { "d": "M11 13c1.93 1.93 2.83 4.17 2 5-.83.83-3.07-.07-5-2-1.93-1.93-2.83-4.17-2-5 .83-.83 3.07.07 5 2Z" }]], "rabbit": [["path", { "d": "M13 16a3 3 0 0 1 2.24 5" }], ["path", { "d": "M18 12h.01" }], ["path", { "d": "M18 21h-8a4 4 0 0 1-4-4 7 7 0 0 1 7-7h.2L9.6 6.4a1 1 0 1 1 2.8-2.8L15.8 7h.2c3.3 0 6 2.7 6 6v1a2 2 0 0 1-2 2h-1a3 3 0 0 0-3 3" }], ["path", { "d": "M20 8.54V4a2 2 0 1 0-4 0v3" }], ["path", { "d": "M7.612 12.524a3 3 0 1 0-1.6 4.3" }]], "headphones": [["path", { "d": "M3 14h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a9 9 0 0 1 18 0v7a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3" }]], "heart": [["path", { "d": "M2 9.5a5.5 5.5 0 0 1 9.591-3.676.56.56 0 0 0 .818 0A5.49 5.49 0 0 1 22 9.5c0 2.29-1.5 4-3 5.5l-5.492 5.313a2 2 0 0 1-3 .019L5 15c-1.5-1.5-3-3.2-3-5.5" }]], "hourglass": [["path", { "d": "M5 22h14" }], ["path", { "d": "M5 2h14" }], ["path", { "d": "M17 22v-4.172a2 2 0 0 0-.586-1.414L12 12l-4.414 4.414A2 2 0 0 0 7 17.828V22" }], ["path", { "d": "M7 2v4.172a2 2 0 0 0 .586 1.414L12 12l4.414-4.414A2 2 0 0 0 17 6.172V2" }]], "house": [["path", { "d": "M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8" }], ["path", { "d": "M3 10a2 2 0 0 1 .709-1.528l7-6a2 2 0 0 1 2.582 0l7 6A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" }]], "tornado": [["path", { "d": "M21 4H3" }], ["path", { "d": "M18 8H6" }], ["path", { "d": "M19 12H9" }], ["path", { "d": "M16 16h-6" }], ["path", { "d": "M11 20H9" }]], "info": [["circle", { "cx": "12", "cy": "12", "r": "10" }], ["path", { "d": "M12 16v-4" }], ["path", { "d": "M12 8h.01" }]], "hard-drive": [["path", { "d": "M10 16h.01" }], ["path", { "d": "M2.212 11.577a2 2 0 0 0-.212.896V18a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-5.527a2 2 0 0 0-.212-.896L18.55 5.11A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z" }], ["path", { "d": "M21.946 12.013H2.054" }], ["path", { "d": "M6 16h.01" }]], "smartphone": [["rect", { "width": "14", "height": "20", "x": "5", "y": "2", "rx": "2", "ry": "2" }], ["path", { "d": "M12 18h.01" }]], "key": [["path", { "d": "m2 21 9.6-9.6" }], ["path", { "d": "m7.5 15.5 2.3 2.3a1 1 0 0 1 0 1.4l-2.1 2.1a1 1 0 0 1-1.4 0L4 19" }], ["circle", { "cx": "15.5", "cy": "7.5", "r": "5.5" }]], "keyboard": [["path", { "d": "M10 8h.01" }], ["path", { "d": "M12 12h.01" }], ["path", { "d": "M14 8h.01" }], ["path", { "d": "M16 12h.01" }], ["path", { "d": "M18 8h.01" }], ["path", { "d": "M6 8h.01" }], ["path", { "d": "M7 16h10" }], ["path", { "d": "M8 12h.01" }], ["rect", { "width": "20", "height": "16", "x": "2", "y": "4", "rx": "2" }]], "laptop": [["path", { "d": "M18 5a2 2 0 0 1 2 2v8.526a2 2 0 0 0 .212.897l1.068 2.127a1 1 0 0 1-.9 1.45H3.62a1 1 0 0 1-.9-1.45l1.068-2.127A2 2 0 0 0 4 15.526V7a2 2 0 0 1 2-2z" }], ["path", { "d": "M20.054 15.987H3.946" }]], "leaf": [["path", { "d": "M11 20a10 10 0 0010-10 25.9 25.9 0 00-1.04-7.281 1 1 0 00-1.755-.325C15.833 5.5 13 5.5 9.8 6.1A7 7 0 0011 20" }], ["path", { "d": "M2 21a5 5 0 012.911-4.544C7.613 15.212 8.351 15.24 11 13" }]], "lightbulb": [["path", { "d": "M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .2 2.2 1.5 3.5.7.7 1.3 1.5 1.5 2.5" }], ["path", { "d": "M9 18h6" }], ["path", { "d": "M10 22h4" }]], "link": [["path", { "d": "M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71" }], ["path", { "d": "M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71" }]], "list": [["path", { "d": "M3 5h.01" }], ["path", { "d": "M3 12h.01" }], ["path", { "d": "M3 19h.01" }], ["path", { "d": "M8 5h13" }], ["path", { "d": "M8 12h13" }], ["path", { "d": "M8 19h13" }]], "list-ordered": [["path", { "d": "M11 5h10" }], ["path", { "d": "M11 12h10" }], ["path", { "d": "M11 19h10" }], ["path", { "d": "M4 4h1v5" }], ["path", { "d": "M4 9h2" }], ["path", { "d": "M6.5 20H3.4c0-1 2.6-1.925 2.6-3.5a1.5 1.5 0 0 0-2.6-1.02" }]], "navigation": [["polygon", { "points": "3 11 22 2 13 21 11 13 3 11" }]], "locate-fixed": [["line", { "x1": "2", "x2": "5", "y1": "12", "y2": "12" }], ["line", { "x1": "19", "x2": "22", "y1": "12", "y2": "12" }], ["line", { "x1": "12", "x2": "12", "y1": "2", "y2": "5" }], ["line", { "x1": "12", "x2": "12", "y1": "19", "y2": "22" }], ["circle", { "cx": "12", "cy": "12", "r": "7" }], ["circle", { "cx": "12", "cy": "12", "r": "3" }]], "navigation-off": [["path", { "d": "M8.43 8.43 3 11l8 2 2 8 2.57-5.43" }], ["path", { "d": "M17.39 11.73 22 2l-9.73 4.61" }], ["line", { "x1": "2", "x2": "22", "y1": "2", "y2": "22" }]], "lock": [["rect", { "width": "18", "height": "11", "x": "3", "y": "11", "rx": "2", "ry": "2" }], ["path", { "d": "M7 11V7a5 5 0 0 1 10 0v4" }]], "lock-open": [["rect", { "width": "18", "height": "11", "x": "3", "y": "11", "rx": "2", "ry": "2" }], ["path", { "d": "M7 11V7a5 5 0 0 1 9.9-1" }]], "shield-check": [["path", { "d": "M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z" }], ["path", { "d": "m9 12 2 2 4-4" }]], "wind": [["path", { "d": "M12.8 19.6A2 2 0 1 0 14 16H2" }], ["path", { "d": "M17.5 8a2.5 2.5 0 1 1 2 4H2" }], ["path", { "d": "M9.8 4.4A2 2 0 1 1 11 8H2" }]], "search": [["path", { "d": "m21 21-4.34-4.34" }], ["circle", { "cx": "11", "cy": "11", "r": "8" }]], "map": [["path", { "d": "M14.106 5.553a2 2 0 0 0 1.788 0l3.659-1.83A1 1 0 0 1 21 4.619v12.764a1 1 0 0 1-.553.894l-4.553 2.277a2 2 0 0 1-1.788 0l-4.212-2.106a2 2 0 0 0-1.788 0l-3.659 1.83A1 1 0 0 1 3 19.381V6.618a1 1 0 0 1 .553-.894l4.553-2.277a2 2 0 0 1 1.788 0z" }], ["path", { "d": "M15 5.764v15" }], ["path", { "d": "M9 3.236v15" }]], "map-pin": [["path", { "d": "M20 10c0 4.993-5.539 10.193-7.399 11.799a1 1 0 0 1-1.202 0C9.539 20.193 4 14.993 4 10a8 8 0 0 1 16 0" }], ["circle", { "cx": "12", "cy": "10", "r": "3" }]], "medal": [["path", { "d": "M7.21 15 2.66 7.14a2 2 0 0 1 .13-2.2L4.4 2.8A2 2 0 0 1 6 2h12a2 2 0 0 1 1.6.8l1.6 2.14a2 2 0 0 1 .14 2.2L16.79 15" }], ["path", { "d": "M11 12 5.12 2.2" }], ["path", { "d": "m13 12 5.88-9.8" }], ["path", { "d": "M8 7h8" }], ["circle", { "cx": "12", "cy": "17", "r": "5" }], ["path", { "d": "M12 18v-2h-.5" }]], "megaphone": [["path", { "d": "M11 6a13 13 0 0 0 8.4-2.8A1 1 0 0 1 21 4v12a1 1 0 0 1-1.6.8A13 13 0 0 0 11 14H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2z" }], ["path", { "d": "M6 14a12 12 0 0 0 2.4 7.2 2 2 0 0 0 3.2-2.4A8 8 0 0 1 10 14" }], ["path", { "d": "M8 6v8" }]], "memory-stick": [["path", { "d": "M12 12v-2" }], ["path", { "d": "M12 18v-2" }], ["path", { "d": "M16 12v-2" }], ["path", { "d": "M16 18v-2" }], ["path", { "d": "M2 11h1.5" }], ["path", { "d": "M20 18v-2" }], ["path", { "d": "M20.5 11H22" }], ["path", { "d": "M4 18v-2" }], ["path", { "d": "M8 12v-2" }], ["path", { "d": "M8 18v-2" }], ["rect", { "x": "2", "y": "6", "width": "20", "height": "10", "rx": "2" }]], "mic": [["path", { "d": "M12 19v3" }], ["path", { "d": "M19 10v2a7 7 0 0 1-14 0v-2" }], ["rect", { "x": "9", "y": "2", "width": "6", "height": "13", "rx": "3" }]], "minus": [["path", { "d": "M5 12h14" }]], "circle-minus": [["circle", { "cx": "12", "cy": "12", "r": "10" }], ["path", { "d": "M8 12h8" }]], "moon": [["path", { "d": "M20.985 12.486a9 9 0 1 1-9.473-9.472c.405-.022.617.46.402.803a6 6 0 0 0 8.268 8.268c.344-.215.825-.004.803.401" }]], "moon-star": [["path", { "d": "M18 5h4" }], ["path", { "d": "M20 3v4" }], ["path", { "d": "M20.985 12.486a9 9 0 1 1-9.473-9.472c.405-.022.617.46.402.803a6 6 0 0 0 8.268 8.268c.344-.215.825-.004.803.401" }]], "layout-grid": [["rect", { "width": "7", "height": "7", "x": "3", "y": "3", "rx": "1" }], ["rect", { "width": "7", "height": "7", "x": "14", "y": "3", "rx": "1" }], ["rect", { "width": "7", "height": "7", "x": "14", "y": "14", "rx": "1" }], ["rect", { "width": "7", "height": "7", "x": "3", "y": "14", "rx": "1" }]], "mountain": [["path", { "d": "m8 3 4 8 5-5 5 15H2L8 3z" }]], "mic-vocal": [["path", { "d": "m11 7.601-5.994 8.19a1 1 0 0 0 .1 1.298l.817.818a1 1 0 0 0 1.314.087L15.09 12" }], ["path", { "d": "M16.5 21.174C15.5 20.5 14.372 20 13 20c-2.058 0-3.928 2.356-6 2-2.072-.356-2.775-3.369-1.5-4.5" }], ["circle", { "cx": "16", "cy": "7", "r": "5" }]], "eighth-note": [["path", { "d": "m19 6-5.2-3.9a.5.5 0 0 0-.8.4V18" }], ["circle", { "cx": "9", "cy": "18", "r": "4" }]], "list-music": [["path", { "d": "M16 5H3" }], ["path", { "d": "M11 12H3" }], ["path", { "d": "M11 19H3" }], ["path", { "d": "M21 16V5" }], ["circle", { "cx": "18", "cy": "16", "r": "3" }]], "network": [["rect", { "x": "16", "y": "16", "width": "6", "height": "6", "rx": "1" }], ["rect", { "x": "2", "y": "16", "width": "6", "height": "6", "rx": "1" }], ["rect", { "x": "9", "y": "2", "width": "6", "height": "6", "rx": "1" }], ["path", { "d": "M5 16v-3a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v3" }], ["path", { "d": "M12 12V8" }]], "newspaper": [["path", { "d": "M15 18h-5" }], ["path", { "d": "M18 14h-8" }], ["path", { "d": "M4 22h16a2 2 0 0 0 2-2V4a2 2 0 0 0-2-2H8a2 2 0 0 0-2 2v16a2 2 0 0 1-4 0v-9a2 2 0 0 1 2-2h2" }], ["rect", { "width": "8", "height": "4", "x": "10", "y": "6", "rx": "1" }]], "notebook-text": [["path", { "d": "M2 6h4" }], ["path", { "d": "M2 10h4" }], ["path", { "d": "M2 14h4" }], ["path", { "d": "M2 18h4" }], ["rect", { "width": "16", "height": "20", "x": "4", "y": "2", "rx": "2" }], ["path", { "d": "M9.5 8h5" }], ["path", { "d": "M9.5 12H16" }], ["path", { "d": "M9.5 16H14" }]], "paintbrush": [["path", { "d": "m14.622 17.897-10.68-2.913" }], ["path", { "d": "M18.376 2.622a1 1 0 1 1 3.002 3.002L17.36 9.643a.5.5 0 0 0 0 .707l.944.944a2.41 2.41 0 0 1 0 3.408l-.944.944a.5.5 0 0 1-.707 0L8.354 7.348a.5.5 0 0 1 0-.707l.944-.944a2.41 2.41 0 0 1 3.408 0l.944.944a.5.5 0 0 0 .707 0z" }], ["path", { "d": "M9 8c-1.804 2.71-3.97 3.46-6.583 3.948a.507.507 0 0 0-.302.819l7.32 8.883a1 1 0 0 0 1.185.204C12.735 20.405 16 16.792 16 15" }]], "palette": [["path", { "d": "M12 22a1 1 0 0 1 0-20 10 9 0 0 1 10 9 5 5 0 0 1-5 5h-2.25a1.75 1.75 0 0 0-1.4 2.8l.3.4a1.75 1.75 0 0 1-1.4 2.8z" }], ["circle", { "cx": "13.5", "cy": "6.5", "r": ".5" }], ["circle", { "cx": "17.5", "cy": "10.5", "r": ".5" }], ["circle", { "cx": "6.5", "cy": "12.5", "r": ".5" }], ["circle", { "cx": "8.5", "cy": "7.5", "r": ".5" }]], "paperclip": [["path", { "d": "m16 6-8.414 8.586a2 2 0 0 0 2.829 2.829l8.414-8.586a4 4 0 1 0-5.657-5.657l-8.379 8.551a6 6 0 1 0 8.485 8.485l8.379-8.551" }]], "send": [["path", { "d": "M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z" }], ["path", { "d": "m21.854 2.147-10.94 10.939" }]], "circle-parking": [["circle", { "cx": "12", "cy": "12", "r": "10" }], ["path", { "d": "M9 17V7h4a3 3 0 0 1 0 6H9" }]], "pause": [["rect", { "x": "14", "y": "3", "width": "5", "height": "18", "rx": "1" }], ["rect", { "x": "5", "y": "3", "width": "5", "height": "18", "rx": "1" }]], "circle-pause": [["circle", { "cx": "12", "cy": "12", "r": "10" }], ["line", { "x1": "10", "x2": "10", "y1": "15", "y2": "9" }], ["line", { "x1": "14", "x2": "14", "y1": "15", "y2": "9" }]], "paw-print": [["circle", { "cx": "11", "cy": "4", "r": "2" }], ["circle", { "cx": "18", "cy": "8", "r": "2" }], ["circle", { "cx": "20", "cy": "16", "r": "2" }], ["path", { "d": "M9 10a5 5 0 0 1 5 5v3.5a3.5 3.5 0 0 1-6.84 1.045Q6.52 17.48 4.46 16.84A3.5 3.5 0 0 1 5.5 10Z" }]], "pencil": [["path", { "d": "M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z" }], ["path", { "d": "m15 5 4 4" }]], "user": [["path", { "d": "M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2" }], ["circle", { "cx": "12", "cy": "7", "r": "4" }]], "users": [["path", { "d": "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" }], ["path", { "d": "M16 3.128a4 4 0 0 1 0 7.744" }], ["path", { "d": "M22 21v-2a4 4 0 0 0-3-3.87" }], ["circle", { "cx": "9", "cy": "7", "r": "4" }]], "key-round": [["path", { "d": "M2.586 17.414A2 2 0 0 0 2 18.828V21a1 1 0 0 0 1 1h3a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h1a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h.172a2 2 0 0 0 1.414-.586l.814-.814a6.5 6.5 0 1 0-4-4z" }], ["circle", { "cx": "16.5", "cy": "7.5", "r": ".5" }]], "circle-user": [["circle", { "cx": "12", "cy": "12", "r": "10" }], ["circle", { "cx": "12", "cy": "10", "r": "3" }], ["path", { "d": "M7 20.662V19a2 2 0 0 1 2-2h6a2 2 0 0 1 2 2v1.662" }]], "phone": [["path", { "d": "M13.832 16.568a1 1 0 0 0 1.213-.303l.355-.465A2 2 0 0 1 17 15h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2A18 18 0 0 1 2 4a2 2 0 0 1 2-2h3a2 2 0 0 1 2 2v3a2 2 0 0 1-.8 1.6l-.468.351a1 1 0 0 0-.292 1.233 14 14 0 0 0 6.392 6.384" }]], "image": [["rect", { "width": "18", "height": "18", "x": "3", "y": "3", "rx": "2", "ry": "2" }], ["circle", { "cx": "9", "cy": "9", "r": "2" }], ["path", { "d": "m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21" }]], "pill": [["path", { "d": "m10.5 20.5 10-10a4.95 4.95 0 1 0-7-7l-10 10a4.95 4.95 0 1 0 7 7Z" }], ["path", { "d": "m8.5 8.5 7 7" }]], "pin": [["path", { "d": "M12 17v5" }], ["path", { "d": "M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z" }]], "play": [["path", { "d": "M5 5a2 2 0 0 1 3.008-1.728l11.997 6.998a2 2 0 0 1 .003 3.458l-12 7A2 2 0 0 1 5 19z" }]], "circle-play": [["path", { "d": "M9 9.003a1 1 0 0 1 1.517-.859l4.997 2.997a1 1 0 0 1 0 1.718l-4.997 2.997A1 1 0 0 1 9 14.996z" }], ["circle", { "cx": "12", "cy": "12", "r": "10" }]], "plus": [["path", { "d": "M5 12h14" }], ["path", { "d": "M12 5v14" }]], "circle-plus": [["circle", { "cx": "12", "cy": "12", "r": "10" }], ["path", { "d": "M8 12h8" }], ["path", { "d": "M12 8v8" }]], "popcorn": [["path", { "d": "M18 8a2 2 0 0 0 0-4 2 2 0 0 0-4 0 2 2 0 0 0-4 0 2 2 0 0 0-4 0 2 2 0 0 0 0 4" }], ["path", { "d": "M10 22 9 8" }], ["path", { "d": "m14 22 1-14" }], ["path", { "d": "M20 8c.5 0 .9.4.8 1l-2.6 12c-.1.5-.7 1-1.2 1H7c-.6 0-1.1-.4-1.2-1L3.2 9c-.1-.6.3-1 .8-1Z" }]], "power": [["path", { "d": "M12 2v10" }], ["path", { "d": "M18.4 6.6a9 9 0 1 1-12.77.04" }]], "printer": [["path", { "d": "M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2" }], ["path", { "d": "M6 9V3a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v6" }], ["rect", { "x": "6", "y": "14", "width": "12", "height": "8", "rx": "1" }]], "puzzle": [["path", { "d": "M15.39 4.39a1 1 0 0 0 1.68-.474 2.5 2.5 0 1 1 3.014 3.015 1 1 0 0 0-.474 1.68l1.683 1.682a2.414 2.414 0 0 1 0 3.414L19.61 15.39a1 1 0 0 1-1.68-.474 2.5 2.5 0 1 0-3.014 3.015 1 1 0 0 1 .474 1.68l-1.683 1.682a2.414 2.414 0 0 1-3.414 0L8.61 19.61a1 1 0 0 0-1.68.474 2.5 2.5 0 1 1-3.014-3.015 1 1 0 0 0 .474-1.68l-1.683-1.682a2.414 2.414 0 0 1 0-3.414L4.39 8.61a1 1 0 0 1 1.68.474 2.5 2.5 0 1 0 3.014-3.015 1 1 0 0 1-.474-1.68l1.683-1.682a2.414 2.414 0 0 1 3.414 0z" }]], "qr-code": [["rect", { "width": "5", "height": "5", "x": "3", "y": "3", "rx": "1" }], ["rect", { "width": "5", "height": "5", "x": "16", "y": "3", "rx": "1" }], ["rect", { "width": "5", "height": "5", "x": "3", "y": "16", "rx": "1" }], ["path", { "d": "M21 16h-3a2 2 0 0 0-2 2v3" }], ["path", { "d": "M21 21v.01" }], ["path", { "d": "M12 7v3a2 2 0 0 1-2 2H7" }], ["path", { "d": "M3 12h.01" }], ["path", { "d": "M12 3h.01" }], ["path", { "d": "M12 16v.01" }], ["path", { "d": "M16 12h1" }], ["path", { "d": "M21 12v.01" }], ["path", { "d": "M12 21v-1" }]], "circle-question-mark": [["circle", { "cx": "12", "cy": "12", "r": "10" }], ["path", { "d": "M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3" }], ["path", { "d": "M12 17h.01" }]], "message-square-quote": [["path", { "d": "M14 14a2 2 0 0 0 2-2V8h-2" }], ["path", { "d": "M22 17a2 2 0 0 1-2 2H6.828a2 2 0 0 0-1.414.586l-2.202 2.202A.71.71 0 0 1 2 21.286V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2z" }], ["path", { "d": "M8 14a2 2 0 0 0 2-2V8H8" }]], "quote": [["path", { "d": "M16 3a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2 1 1 0 0 1 1 1v1a2 2 0 0 1-2 2 1 1 0 0 0-1 1v2a1 1 0 0 0 1 1 6 6 0 0 0 6-6V5a2 2 0 0 0-2-2z" }], ["path", { "d": "M5 3a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2 1 1 0 0 1 1 1v1a2 2 0 0 1-2 2 1 1 0 0 0-1 1v2a1 1 0 0 0 1 1 6 6 0 0 0 6-6V5a2 2 0 0 0-2-2z" }]], "rainbow": [["path", { "d": "M22 17a10 10 0 0 0-20 0" }], ["path", { "d": "M6 17a6 6 0 0 1 12 0" }], ["path", { "d": "M10 17a2 2 0 0 1 4 0" }]], "layers": [["path", { "d": "M12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83z" }], ["path", { "d": "M2 12a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 0 22 12" }], ["path", { "d": "M2 17a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 0 22 17" }]], "repeat": [["path", { "d": "m17 2 4 4-4 4" }], ["path", { "d": "M3 11v-1a4 4 0 0 1 4-4h14" }], ["path", { "d": "m7 22-4-4 4-4" }], ["path", { "d": "M21 13v1a4 4 0 0 1-4 4H3" }]], "award": [["path", { "d": "m15.477 12.89 1.515 8.526a.5.5 0 0 1-.81.47l-3.58-2.687a1 1 0 0 0-1.197 0l-3.586 2.686a.5.5 0 0 1-.81-.469l1.514-8.526" }], ["circle", { "cx": "12", "cy": "8", "r": "6" }]], "compass": [["circle", { "cx": "12", "cy": "12", "r": "10" }], ["path", { "d": "m16.24 7.76-1.804 5.411a2 2 0 0 1-1.265 1.265L7.76 16.24l1.804-5.411a2 2 0 0 1 1.265-1.265z" }]], "sailboat": [["path", { "d": "M10 2v15" }], ["path", { "d": "M7 22a4 4 0 0 1-4-4 1 1 0 0 1 1-1h16a1 1 0 0 1 1 1 4 4 0 0 1-4 4z" }], ["path", { "d": "M9.159 2.46a1 1 0 0 1 1.521-.193l9.977 8.98A1 1 0 0 1 20 13H4a1 1 0 0 1-.824-1.567z" }]], "scissors": [["circle", { "cx": "6", "cy": "6", "r": "3" }], ["path", { "d": "M8.12 8.12 12 12" }], ["path", { "d": "M20 4 8.12 15.88" }], ["circle", { "cx": "6", "cy": "18", "r": "3" }], ["path", { "d": "M14.8 14.8 20 20" }]], "crosshair": [["circle", { "cx": "12", "cy": "12", "r": "10" }], ["line", { "x1": "22", "x2": "18", "y1": "12", "y2": "12" }], ["line", { "x1": "6", "x2": "2", "y1": "12", "y2": "12" }], ["line", { "x1": "12", "x2": "12", "y1": "6", "y2": "2" }], ["line", { "x1": "12", "x2": "12", "y1": "22", "y2": "18" }]], "wrench": [["path", { "d": "M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.106-3.105c.32-.322.863-.22.983.218a6 6 0 0 1-8.259 7.057l-7.91 7.91a1 1 0 0 1-2.999-3l7.91-7.91a6 6 0 0 1 7.057-8.259c.438.12.54.662.219.984z" }]], "shield": [["path", { "d": "M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z" }]], "package": [["path", { "d": "M11 21.73a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73z" }], ["path", { "d": "M12 22V12" }], ["polyline", { "points": "3.29 7 12 12 20.71 7" }], ["path", { "d": "m7.5 4.27 9 5.15" }]], "signpost": [["path", { "d": "M12 13v8" }], ["path", { "d": "M12 3v3" }], ["path", { "d": "M2.354 10.354a1.207 1.207 0 0 1 0-1.708l2.06-2.06A2 2 0 0 1 5.828 6h12.344a2 2 0 0 1 1.414.586l2.06 2.06a1.207 1.207 0 0 1 0 1.708l-2.06 2.06a2 2 0 0 1-1.414.586H5.828a2 2 0 0 1-1.414-.586z" }]], "snowflake": [["path", { "d": "m10 20-1.25-2.5L6 18" }], ["path", { "d": "M10 4 8.75 6.5 6 6" }], ["path", { "d": "m14 20 1.25-2.5L18 18" }], ["path", { "d": "m14 4 1.25 2.5L18 6" }], ["path", { "d": "m17 21-3-6h-4" }], ["path", { "d": "m17 3-3 6 1.5 3" }], ["path", { "d": "M2 12h6.5L10 9" }], ["path", { "d": "m20 10-1.5 2 1.5 2" }], ["path", { "d": "M22 12h-6.5L14 15" }], ["path", { "d": "m4 10 1.5 2L4 14" }], ["path", { "d": "m7 21 3-6-1.5-3" }], ["path", { "d": "m7 3 3 6h4" }]], "sofa": [["path", { "d": "M20 9V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v3" }], ["path", { "d": "M2 16a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-5a2 2 0 0 0-4 0v1.5a.5.5 0 0 1-.5.5h-11a.5.5 0 0 1-.5-.5V11a2 2 0 0 0-4 0z" }], ["path", { "d": "M4 18v2" }], ["path", { "d": "M20 18v2" }], ["path", { "d": "M12 4v9" }]], "sparkle": [["path", { "d": "M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z" }]], "sparkles": [["path", { "d": "M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z" }], ["path", { "d": "M20 2v4" }], ["path", { "d": "M22 4h-4" }], ["circle", { "cx": "4", "cy": "20", "r": "2" }]], "volume-2": [["path", { "d": "M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z" }], ["path", { "d": "M16 9a5 5 0 0 1 0 6" }], ["path", { "d": "M19.364 18.364a9 9 0 0 0 0-12.728" }]], "square": [["rect", { "width": "18", "height": "18", "x": "3", "y": "3", "rx": "2" }]], "share": [["path", { "d": "M12 2v13" }], ["path", { "d": "m16 6-4-4-4 4" }], ["path", { "d": "M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8" }]], "square-pen": [["path", { "d": "M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7" }], ["path", { "d": "M18.375 2.625a1 1 0 0 1 3 3l-9.013 9.014a2 2 0 0 1-.853.505l-2.873.84a.5.5 0 0 1-.62-.62l.84-2.873a2 2 0 0 1 .506-.852z" }]], "star": [["path", { "d": "M11.525 2.295a.53.53 0 0 1 .95 0l2.31 4.679a2.123 2.123 0 0 0 1.595 1.16l5.166.756a.53.53 0 0 1 .294.904l-3.736 3.638a2.123 2.123 0 0 0-.611 1.878l.882 5.14a.53.53 0 0 1-.771.56l-4.618-2.428a2.122 2.122 0 0 0-1.973 0L6.396 21.01a.53.53 0 0 1-.77-.56l.881-5.139a2.122 2.122 0 0 0-.611-1.879L2.16 9.795a.53.53 0 0 1 .294-.906l5.165-.755a2.122 2.122 0 0 0 1.597-1.16z" }]], "asterisk": [["path", { "d": "M12 5v14" }], ["path", { "d": "m18.065 8.496-12.125 7" }], ["path", { "d": "m5.94 8.504 12.125 7" }]], "timer": [["line", { "x1": "10", "x2": "14", "y1": "2", "y2": "2" }], ["line", { "x1": "12", "x2": "15", "y1": "14", "y2": "11" }], ["circle", { "cx": "12", "cy": "14", "r": "8" }]], "store": [["path", { "d": "M15 21v-5a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v5" }], ["path", { "d": "M17.774 10.31a1.12 1.12 0 0 0-1.549 0 2.5 2.5 0 0 1-3.451 0 1.12 1.12 0 0 0-1.548 0 2.5 2.5 0 0 1-3.452 0 1.12 1.12 0 0 0-1.549 0 2.5 2.5 0 0 1-3.77-3.248l2.889-4.184A2 2 0 0 1 7 2h10a2 2 0 0 1 1.653.873l2.895 4.192a2.5 2.5 0 0 1-3.774 3.244" }], ["path", { "d": "M4 10.95V19a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8.05" }]], "luggage": [["path", { "d": "M6 20a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2" }], ["path", { "d": "M8 18V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v14" }], ["path", { "d": "M10 20h4" }], ["circle", { "cx": "16", "cy": "20", "r": "2" }], ["circle", { "cx": "8", "cy": "20", "r": "2" }]], "haze": [["path", { "d": "m5.2 6.2 1.4 1.4" }], ["path", { "d": "M2 13h2" }], ["path", { "d": "M20 13h2" }], ["path", { "d": "m17.4 7.6 1.4-1.4" }], ["path", { "d": "M22 17H2" }], ["path", { "d": "M22 21H2" }], ["path", { "d": "M16 13a4 4 0 0 0-8 0" }], ["path", { "d": "M12 5V2.5" }]], "sun": [["circle", { "cx": "12", "cy": "12", "r": "4" }], ["path", { "d": "M12 2v2" }], ["path", { "d": "M12 20v2" }], ["path", { "d": "m4.93 4.93 1.41 1.41" }], ["path", { "d": "m17.66 17.66 1.41 1.41" }], ["path", { "d": "M2 12h2" }], ["path", { "d": "M20 12h2" }], ["path", { "d": "m6.34 17.66-1.41 1.41" }], ["path", { "d": "m19.07 4.93-1.41 1.41" }]], "sun-dim": [["circle", { "cx": "12", "cy": "12", "r": "4" }], ["path", { "d": "M12 4h.01" }], ["path", { "d": "M20 12h.01" }], ["path", { "d": "M12 20h.01" }], ["path", { "d": "M4 12h.01" }], ["path", { "d": "M17.657 6.343h.01" }], ["path", { "d": "M17.657 17.657h.01" }], ["path", { "d": "M6.343 17.657h.01" }], ["path", { "d": "M6.343 6.343h.01" }]], "sunrise": [["path", { "d": "M12 2v8" }], ["path", { "d": "m4.93 10.93 1.41 1.41" }], ["path", { "d": "M2 18h2" }], ["path", { "d": "M20 18h2" }], ["path", { "d": "m19.07 10.93-1.41 1.41" }], ["path", { "d": "M22 22H2" }], ["path", { "d": "m8 6 4-4 4 4" }], ["path", { "d": "M16 18a4 4 0 0 0-8 0" }]], "sunset": [["path", { "d": "M12 10V2" }], ["path", { "d": "m4.93 10.93 1.41 1.41" }], ["path", { "d": "M2 18h2" }], ["path", { "d": "M20 18h2" }], ["path", { "d": "m19.07 10.93-1.41 1.41" }], ["path", { "d": "M22 22H2" }], ["path", { "d": "m16 6-4 4-4-4" }], ["path", { "d": "M16 18a4 4 0 0 0-8 0" }]], "tag": [["path", { "d": "M12.586 2.586A2 2 0 0 0 11.172 2H4a2 2 0 0 0-2 2v7.172a2 2 0 0 0 .586 1.414l8.704 8.704a2.426 2.426 0 0 0 3.42 0l6.58-6.58a2.426 2.426 0 0 0 0-3.42z" }], ["circle", { "cx": "7.5", "cy": "7.5", "r": ".5" }]], "target": [["circle", { "cx": "12", "cy": "12", "r": "10" }], ["circle", { "cx": "12", "cy": "12", "r": "6" }], ["circle", { "cx": "12", "cy": "12", "r": "2" }]], "text-align-start": [["path", { "d": "M21 5H3" }], ["path", { "d": "M15 12H3" }], ["path", { "d": "M17 19H3" }]], "drama": [["path", { "d": "M10 11h.01" }], ["path", { "d": "M14 6h.01" }], ["path", { "d": "M18 6h.01" }], ["path", { "d": "M6.5 13.1h.01" }], ["path", { "d": "M22 5c0 9-4 12-6 12s-6-3-6-12c0-2 2-3 6-3s6 1 6 3" }], ["path", { "d": "M17.4 9.9c-.8.8-2 .8-2.8 0" }], ["path", { "d": "M10.1 7.1C9 7.2 7.7 7.7 6 8.6c-3.5 2-4.7 3.9-3.7 5.6 4.5 7.8 9.5 8.4 11.2 7.4.9-.5 1.9-2.1 1.9-4.7" }], ["path", { "d": "M9.1 16.5c.3-1.1 1.4-1.7 2.4-1.4" }]], "thermometer-sun": [["path", { "d": "M12 2v2" }], ["path", { "d": "M12 8a4 4 0 0 0-1.645 7.647" }], ["path", { "d": "M2 12h2" }], ["path", { "d": "M20 14.54a4 4 0 1 1-4 0V4a2 2 0 0 1 4 0z" }], ["path", { "d": "m4.93 4.93 1.41 1.41" }], ["path", { "d": "m6.34 17.66-1.41 1.41" }]], "ticket": [["path", { "d": "M2 9a3 3 0 0 1 0 6v2a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-2a3 3 0 0 1 0-6V7a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2Z" }], ["path", { "d": "M13 5v2" }], ["path", { "d": "M13 17v2" }], ["path", { "d": "M13 11v2" }]], "turtle": [["path", { "d": "m12 10 2 4v3a1 1 0 0 0 1 1h2a1 1 0 0 0 1-1v-3a8 8 0 1 0-16 0v3a1 1 0 0 0 1 1h2a1 1 0 0 0 1-1v-3l2-4h4Z" }], ["path", { "d": "M4.82 7.9 8 10" }], ["path", { "d": "M15.18 7.9 12 10" }], ["path", { "d": "M16.93 10H20a2 2 0 0 1 0 4H2" }]], "fingerprint-pattern": [["path", { "d": "M12 10a2 2 0 0 0-2 2c0 1.02-.1 2.51-.26 4" }], ["path", { "d": "M14 13.12c0 2.38 0 6.38-1 8.88" }], ["path", { "d": "M17.29 21.02c.12-.6.43-2.3.5-3.02" }], ["path", { "d": "M2 12a10 10 0 0 1 18-6" }], ["path", { "d": "M2 16h.01" }], ["path", { "d": "M21.8 16c.2-2 .131-5.354 0-6" }], ["path", { "d": "M5 19.5C5.5 18 6 15 6 12a6 6 0 0 1 .34-2" }], ["path", { "d": "M8.65 22c.21-.66.45-1.32.57-2" }], ["path", { "d": "M9 6.8a6 6 0 0 1 9 5.2v2" }]], "tram-front": [["rect", { "width": "16", "height": "16", "x": "4", "y": "3", "rx": "2" }], ["path", { "d": "M4 11h16" }], ["path", { "d": "M12 3v8" }], ["path", { "d": "m8 19-2 3" }], ["path", { "d": "m18 22-2-3" }], ["path", { "d": "M8 15h.01" }], ["path", { "d": "M16 15h.01" }]], "trash": [["path", { "d": "M10 11v6" }], ["path", { "d": "M14 11v6" }], ["path", { "d": "M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6" }], ["path", { "d": "M3 6h18" }], ["path", { "d": "M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" }]], "inbox": [["polyline", { "points": "22 12 16 12 14 15 10 15 8 12 2 12" }], ["path", { "d": "M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z" }]], "tree-pine": [["path", { "d": "m17 14 3 3.3a1 1 0 0 1-.7 1.7H4.7a1 1 0 0 1-.7-1.7L7 14h-.3a1 1 0 0 1-.7-1.7L9 9h-.2A1 1 0 0 1 8 7.3L12 3l4 4.3a1 1 0 0 1-.8 1.7H15l3 3.3a1 1 0 0 1-.7 1.7H17Z" }], ["path", { "d": "M12 22v-3" }]], "trophy": [["path", { "d": "M10 14.66V17a1 1 0 0 1-1 1 2 2 0 0 0-2 2v2" }], ["path", { "d": "M14 14.66V17a1 1 0 0 0 1 1 2 2 0 0 1 2 2v2" }], ["path", { "d": "M17.916 10H19.5A2.5 2.5 0 0 0 22 7.5V5a1 1 0 0 0-1-1h-3" }], ["path", { "d": "M4 22h16" }], ["path", { "d": "M6 9a6 6 0 0 0 12 0V3a1 1 0 0 0-1-1H7a1 1 0 0 0-1 1z" }], ["path", { "d": "M6.084 10H4.5A2.5 2.5 0 0 1 2 7.5V5a1 1 0 0 1 1-1h3" }]], "tv": [["path", { "d": "m17 2-5 5-5-5" }], ["rect", { "width": "20", "height": "15", "x": "2", "y": "7", "rx": "2" }]], "umbrella": [["path", { "d": "M12 13v7a2 2 0 0 0 4 0" }], ["path", { "d": "M12 2v2" }], ["path", { "d": "M20.992 13a1 1 0 0 0 .97-1.274 10.284 10.284 0 0 0-19.923 0A1 1 0 0 0 3 13z" }]], "video": [["path", { "d": "m16 13 5.223 3.482a.5.5 0 0 0 .777-.416V7.87a.5.5 0 0 0-.752-.432L16 10.5" }], ["rect", { "x": "2", "y": "6", "width": "14", "height": "12", "rx": "2" }]], "wallet": [["path", { "d": "M19 7V4a1 1 0 0 0-1-1H5a2 2 0 0 0 0 4h15a1 1 0 0 1 1 1v4h-3a2 2 0 0 0 0 4h3a1 1 0 0 0 1-1v-2a1 1 0 0 0-1-1" }], ["path", { "d": "M3 5v14a2 2 0 0 0 2 2h15a1 1 0 0 0 1-1v-4" }]], "wand-sparkles": [["path", { "d": "m21.64 3.64-1.28-1.28a1.21 1.21 0 0 0-1.72 0L2.36 18.64a1.21 1.21 0 0 0 0 1.72l1.28 1.28a1.2 1.2 0 0 0 1.72 0L21.64 5.36a1.2 1.2 0 0 0 0-1.72" }], ["path", { "d": "m14 7 3 3" }], ["path", { "d": "M5 6v4" }], ["path", { "d": "M19 14v4" }], ["path", { "d": "M10 2v2" }], ["path", { "d": "M7 8H3" }], ["path", { "d": "M21 16h-4" }], ["path", { "d": "M11 3H9" }]], "audio-lines": [["path", { "d": "M2 10v3" }], ["path", { "d": "M6 6v11" }], ["path", { "d": "M10 3v18" }], ["path", { "d": "M14 8v7" }], ["path", { "d": "M18 5v13" }], ["path", { "d": "M22 10v3" }]], "activity": [["path", { "d": "M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.49 12H2" }]], "wifi": [["path", { "d": "M12 20h.01" }], ["path", { "d": "M2 8.82a15 15 0 0 1 20 0" }], ["path", { "d": "M5 12.859a10 10 0 0 1 14 0" }], ["path", { "d": "M8.5 16.429a5 5 0 0 1 7 0" }]], "wifi-off": [["path", { "d": "M12 20h.01" }], ["path", { "d": "M8.5 16.429a5 5 0 0 1 7 0" }], ["path", { "d": "M5 12.859a10 10 0 0 1 5.17-2.69" }], ["path", { "d": "M19 12.859a10 10 0 0 0-2.007-1.523" }], ["path", { "d": "M2 8.82a15 15 0 0 1 4.177-2.643" }], ["path", { "d": "M22 8.82a15 15 0 0 0-11.288-3.764" }], ["path", { "d": "m2 2 20 20" }]], "x": [["path", { "d": "M18 6 6 18" }], ["path", { "d": "m6 6 12 12" }]], "circle-x": [["circle", { "cx": "12", "cy": "12", "r": "10" }], ["path", { "d": "m15 9-6 6" }], ["path", { "d": "m9 9 6 6" }]] };

  // ../Web/preview-engine/src/render/hyphenation.generated.js
  var hyphenationPatterns = Object.freeze({ "leftmin": 2, "rightmin": 3, "patterns": { "3": "x1qei2e1je1f1to2tlou2w3c1tue1q4tvtw41tyo1q4tz4tcd2yd1wd1v1du1ta4eu1pas4y1droo2d1psw24sv1dod1m1fad1j1su4fdo2n4fh1fi4fm4fn1fopd42ft3fu1fy1ga2sss1ru5jd5cd1bg3bgd44uk2ok1cyo5jgl2g1m4pf4pg1gog3p1gr1soc1qgs2oi2g3w1gysk21coc5nh1bck1h1fh1h4hk1zo1ci4zms2hh1w2ch5zl2idc3c2us2igi3hi3j4ik1cab1vsa22btr1w4bp2io2ipu3u4irbk4b1j1va2ze2bf4oar1p4nz4zbi1u2iv4iy5ja1jeza1y1wk1bk3fkh4k1ikk4k1lk1mk5tk1w2ldr1mn1t2lfr1lr3j4ljl1l2lm2lp4ltn1rrh4v4yn1q1ly1maw1brg2r1fwi24ao2mhw4kr1cw5p4mkm1m1mo4wtwy4x1ar1ba2nn5mx1ex1h4mtx3i1muqu2p3wx3o4mwa1jx3p1naai2x1ua2fxx4y1ba2dn1jy1cn3fpr2y1dy1i", "4": "4dryn2itni4on1inn1im_up3nik4ni4dy5giye4tyes4_ye44ab_nhe4nha4abe2n2gyn1guy1ery5eep2pe4abry3lay3lone4wne4v1nesy3chn1erne2q3neo1nenp2seps4hy2cey5lu2nedne2cyme44nk2y5at2adine2b2ne_y5ac2p1tp2ten1den1cun1cryn5dp2th4adup4twpub3ae4rxu3ayn5gaff4pue4n2au4p1ppuf4n2atag1ipu4mag1na2gon4asx3tix1t2pu2na4gya3haa3heah4la3ho_ti2a5ian2an5puspu2tnak4_th2n1kl_te4_ta4mu4u4mupmun23mum2alex4ob_sy25ynxal1i_st4y1o4xi5cxi5a4alm_si2_sh2m5sixhu4m4sh4m3r4amam2py2rabm2pixhi2yo5dr2ai4m1pmo2vmos2x2edmo2r4n1la2mor2asx3c2xas5yom4x4apxam3nme44mokrbi2nne44andy4osp4ot3noemn4omn4a4m1n4nog4m1l2angws4l1posw3shwri4wra4yp3iwom11wo2m2izrb4ow4nopo4pr2cem2isrd2iano4mig4y3pomi3awiz55mi_no4n4m1fme4v2re_wir42mes1menme2mme2gre1o2med4me_4nop4m5c4m1bwil21noureu2whi4w3ev4maprev2w1era2plpo4crfu4r4fyy5pu2maha3pu2mab2a2rn1p4npi44lyb4lya2p3nwam42l1w1lut4luplu3or1glluf4lu5a2wacltu2y3rol1tr4vv4r3guyr4rl1te4rh_nru4ar1il2sel4sc4l1rl5prl4plys4c4lovri3ar4ib4lof3lo_ar2par3q_os3ll4oll2i4as_ri1o3vokl2levoi44p1mlka35vo_ns4cas4ll1izr4iqr2is3vivl1it3lika2tan2sen2slrle42l3hlgo3l5gal5frns3mvi4p3ley_od2r2meles24athr4myle2al3drv1inldi4l2de2vilnt2il3civik4lce42l1b4lavv3ifrno4r3nua1trr2ocnt4sy4sok4syks4la2tuk4sck3ouko5ryss4a2tyau4b4klyys1tnu1akis4au3rki4pro4ek4ima2va5ki_nu4dn4umn3uokes4k1erav1irok2ke4g1keek2ed_me2aw3ikal4aws4k5agk3ab3ka_aye4ays4veg3jo4p5ba_4vedjew3n1v24ve_ja4pzar23vatizi4n1w41batba4z2b1bb2beix4o4i5w4b1d4be_rox5nym4nyp4n3za4ittr3por1r4i1ti1bel2ith2itei2su4rs2r1sars4cr2seis1p3betvag4i2sor1shbe3wr1sioad34b3hbi2bbi4d3bie3isf4ise2is_1bilr1sp5va_r5sw_le2uz4eir1ibi2tuxu3r1tiu1v2i1raze4nze4pb2l2uu4mo1biip3iz1eripe4b4louts44b1m4b3no3br3bodi4osbo4eru3aio4mi1ol4io_3booo1ce4inyin1u2insru2n2inn4inl4inkrv4e2inioch42iner3vo4indpi2np4idbt4lb4tob3trry4cry3t2in_o4elbu4ni2muim1i5saiil3v4ilnil1iil5fs1apo3er4b5w5by_bys4_in1sau4i1lazet4u2suo3ev2z1ii2go4igius1p5saw4s5bo2fi4ifti3fl4if_i3etsch2usc22ie4i2dui4dri2diid5dpi3au3ruz4ils1cuz4is4s5d4se_se4a2ce_2ici4ich3ceii1bri5bo1ceni1blse2g5seiibe43cepi2aniam4ur2li2al2i1acet4hy2scew41phy4ch_5phuhu4thu4gche2h4tyh4shur1durc44hr44h5p5sev5sexu1ra4s3fup3p2s3gph3t2sh_ho4g2h1n_he23ciau3pl4h1mci5ch2lozo4m4ciihi2vhi4p2cim2cin4phsu1peu1ouo1geu5osheu4sho4he4th1es4shwun5zun5ysi1bunu45cizo4glck3ihep5he2nh4ed1sioph2l5hazsi2rcly4zte4_ge21siscoe22cog5siu1siv5siz_ga24skes1l2s2leha4m2s1ms3ma1ogyo1h2u1ni3gus3gun2guegu4acov1gth3_eu3g4ros1n4_es3u2nez4zyum2pu1mi3som_ev2oig4cri2gov15goos4opgon2ul5v5goeu3lugob53go_2c1t4ph_g1nog1nic2te4sov4ulsgn4ag4myc4twcud5c4ufc4uipe2t3glo1gleul2igla4_eg23giz3cun5givgi4u3gir5gio1cusul4e2spagil4g1ic5gi__eb4cze41d2a5da_u1laggo44daf2dagg2gege4v1geo1gen2ged3dato1la2ge_ol2dol2i5daypek4p4eed1d42de_4gazol2tuiv3ol2vo2lys1sa2gamgaf4o2meui4n2ui2pe2cd4em4fugi4jku3fl3ufaf2tyf4to1denu4du4pe_2f3sfri2de1ps1si4f5pfos5d3eqs4sls4snfo2rss2tdes25fon4p1b_ci23payss5w2st_de1tf4l2de1v2fin4dey4d1fd4gast2idg1id2gyd1h25di_ud5dfi3au4cy_ch4pav43didu3cud1iff2fyu3crd1inst4r4f1ffev4fer11dio2fedfe4bdir2s2ty4fe_dis1on1au3ca4f5bon1c2ondd5k25far4fagpa1peys45eyc1exps4ul2dlyp4ale3whon3s3do_e1wa5doee5vud4oge1visu2msu2nub4euav4su2rp4ai6rk_d4or3dosu1atdo4v3doxp4adoo4k4swoo2padre4eus4e3upe5un2ophet5z4syc3syl4y3hoy1ads4pd4swd4syd2tho4wo3ta_du2c4etn2tabta2luac4es4wdu4g2ess4uabdu4n4duptav4st5bow1io1pr5dyn2tawe1sp2t1bop1uead1tz4et4chopy5ea4l4t1d4te_2tyle1si4esh1tee4tyat1cr4twoteg4es2c4eru1teoer1s2eroea2tte4po1rat1wh3tusea2v3teu3texer1i2e1ber1h4tey2t1f4t1ge3br2th_th2e4thle1ce3tumec2i2ths2erb1tia4tueer1aou5vtud2tif22tige1potu1aou4lttu41timt5toos4le1cre2pat4swe5owe1cue4ottsh4eos4e1ort4sce3ol4edieo2ge5of1tio4eno4enn5tiq4edoti4u1tive3my1tiz4othee2ct5laee2ft5lo4t1mee2mtme4e1meem5bcoi4to3be5exo1ry2tof1effel2iel2ftos24t1pe1la1traos2ceig2ei5de5ico2soe1h45egyeg5n", "5": "_ach4e4go_e4goseg1ule5gurtre5feg4iceher4eg5ibeger44egaltre4mei5gle3imbe3infe1ingtra3beir4deit3eei3the5ity5triae4jud3efiteki4nek4la2trime4la_e4lactri4v4toute4law5toure3leaefil45elece4ledto2rae5len4tonye1lestro3ve4fic4tonoto3mytom4bto2mato5ice5limto2gre3lioe2listru5i4todo4ellaee4tyello4e5locel5ogeest4el2shel4tae5ludel5uge4mace4mage5man2t1n2ee2s4ee4p1e2mele4metee4naemi4eee4lyeel3i3tled3tle_e4mistlan4eed3iem3iztrus4emo4gti3zaem3pie4mule4dulemu3ne4dritiv4aedon2e4dolti3tle5neae5neeen3emtis4pti5sotis4m3tisee3newti3sae5niee5nile3nioedi5zen3ite5niu5enized1ited3imeno4ge4nosen3oven4swti5oc4t1s2en3uaen5ufe3ny_4en3zed3ibe3diae4oi4ede4s3tini4ed3deo3ret2ina2e2dae4culeo4toe5outec4te4t3t2t4tes2t1ine5pel4timpe2corephe4e4plie2col5tigutu3arti5fytu4bie3pro3tienep4sh5tidie4putt4icoeci4t4tick2ti2bec3imera4bti4aber3ar4tuf45tu3ier4bler3che4cib2ere_4thooecca54thil3thet4thea3turethan4e4cade4bitere4qe4ben5turieret4tur5oeav5oeav5itu5ry4tess4tes_ter5ve1rio4eriter4iueri4v1terier3m4ter3cte5pe4t1waer3noeast3er5obe5rocero4rer1oue3assea5sp1tent4ertler3twtwis4eru4t3tende1s4a3tenc5telsear2te2scateli4e3scres5cue1s2ee2sec3tel_te5giear5kear4cte5diear3ae3sha2t1ede5ande2sice2sid5tecttece44teattype3ty5phesi4uea4gees4mie2sole3acte2sone1a4bdys5pdy4sedu4petaun4d3uleta5sytas4e4tare4tarctar4ata5pl2estrta5mo4talke2surtal3idu5eleta4bta5lae3teoua5naet1ic4taf4etin4ta5doe5tir4taciuan4id1ucad1u1ae3trae3tre2d1s2syn5ouar2d4drowet3uaet5ymdro4pdril4dri4b5dreneu3rouar3ieute44draieu5truar3te2vasdop4pe5veadoo3ddoni4u4belsum3iev1erdoli4do4laev3idevi4le4vinevi4ve5voc2d5ofdo5dee4wage5wee4d1n4ewil54d5lue3wit2d3lou3ber5eye_u1b4i3dledfa3blfab3rfa4ce3dle_fain4suit3su5issu2g34d5lasu4b3fa3tasu1al4fato1di1vd2iti5disiuci4bfeas4di1redi4pl4feca5fectdio5gfe3life4mofen2d4st3wuc4it5ferr5diniucle3f4fesf4fie4stry1dinaf4flydi3ge3dictd4icedia5bs4tops1tle5stirs3tifs4ties1ticfic4is5tias4ti_4ficsfi3cuud3ers3thefil5iste2w4filyudev45finas4tedfi2nes2talfin4ns2tagde2tode4suflin4u1dicf2ly5ud5isu5ditde1scd2es_der5sfon4tu4don5dermss4lid4erhfor4is4siede2pudepi4fra4tf5reade3pade3nufril4frol5ud4side3nou4eneuens4ug5infu5el5dem_s5setfu5nefu3rifusi4fus4s4futade5lode5if4dee_5gal_3galiga3lo2d1eds3selg5amos2s5cssas3u1ing4ganouir4mgass4gath3uita4deaf5dav5e5dav44dato4darygeez44spotspor4s4pon4gelydark5s4ply4spio4geno4genydard5ge3omg4ery5gesigeth54getoge4tydan3g4g1g2da2m2g3gergglu5dach4gh3inspil4gh4to4cutr1gi4agia5rula5bspho5g4icogien5s2pheulch42sperspa4n5spai3c4utu1lenul4gigir4lg3islcu5pycu3picu4mic3umecu2maso5vi5glasu5liagli4bg3lig5culiglo3r4ul3mctu4ru1l4og4na_c3terul1tig2ning4nio4ultug4noncta4b4c3s2cru4dul5ulsor5dgo3isum5absor5ccris4go3nic4rinson4gsona45gos_cri5fcre4vum4bi5credg4raigran25solvsoft3so4ceunat44graygre4nco5zi4gritcoz5egruf4cow5ag5stecove4cos4es5menun4ersmel44corbco4pl4gu4tco3pacon5tsman3gy5racon3ghach4hae4mhae4th5aguha3lac4onecon4aun4ims3latu2ninhan4gs3ket5colocol5ihan4kuni3vhap3lhap5ttras4co4grhar2dco5agsir5aclim45sionhas5shaun44clichaz3acle4m1head3hearun3s4s3ingun4sws2ina2s1in4silysil4eh5elohem4p4clarhena45sidiheo5r1c4l4h4eras5icc2c1itu4orsh3ernshor4h3eryci3phshon34cipecion45cinoc1ingc4inahi5anhi4cohigh5h4il2shiv5h4ina3ship3cilihir4lhi3rohir4phir4rsh3iohis4ssh1inci4lau5pia4h1l4hlan44cier5shevcia5rhmet4ch4tish1erh5ods3cho2hoge4chi2z3chitho4mahome3hon4aho5ny3hoodhoon45chiouptu44ura_ho5ruhos4esew4ihos1p1housu4ragses5tu4rasur4behree5se5shs1e4s4h1s24chedh4tarht1enht5esur4fru3rifser4os4erlhun4tsen5gur1inu3riosen4dhy3pehy3phu1ritces5tur3iz4cesa4sencur4no4iancian3i4semeia5peiass45selv5selfi4atu3centse1le4ceniib5iaib3inseg3ruros43cencib3li3cell5cel_s5edli5bun4icam5icap4icar4s4ed3secticas5i4cayiccu44iceour4pe4ced_i5cidsea5wi2cipseas4i4clyur4pi4i1cr5icrai4cryic4teictu2ccon4urti4ic4umic5uoi3curcci4ai4daiccha5ca4thscof4ide4s4casys4cliscle5i5dieid3ios4choid1itid5iui3dlei4domid3owu5sadu5sanid5uous4apied4ecany4ield3s4cesien4ei5enn4sceii1er_i3esci1estus3ciuse5as4cedscav5if4frsca4pi3fieu5siau3siccan4eiga5bcan5d4calous5sli3gibig3ilig3inig3iti4g4lus1trig3orig5oti5greigu5iig1ur2c5ah4i5i44cag4cach4ca1blusur4sat3usa5tab5utoi3legil1erilev4uta4b4butail3iail2ibil3io3sanc2ilitil2izsal4t5bustil3oqil4tyil5uru3tati4magsa5losal4m4ute_4imetbu3res3act5sack2s1ab4imitim4nii3mon4utelbumi4bu3libu4ga4inav4utenbsor42b5s2u4tis4briti3neervi4vr3vic4inga4inger3vey4ingir3ven4ingo4inguu4t1li5ni_i4niain3ioin1isbo4tor5uscrunk5both5b5ota5bos42i1no5boriino4si4not5borein3seru3in2int_ru4glbor5di5nusut5of5bor_uto5gioge4io2grbon4au5tonru3enu4touion3iio5phior3ibod3iio5thi5otiio4toi4ourbne5gb3lisrt4shblen4ip4icr3triip3uli3quar4tivr3tigrti4db4le_b5itzira4bi4racird5ert5ibi4refbi3tri4resir5gibi5ourte5oir4isr3tebr4tagbin4diro4gvac3uir5ul2b3ifis5agis3arisas52is1cis3chbi4eris3erbi5enrson3be5yor5shais3ibisi4di5sisbe3tw4is4krs3es4ismsbe5trr3secva4geis2piis4py4is1sbe3sp4bes4be5nuval5ois1teis1tirrys4rros44be5mis5us4ita_rron4i4tagrri4vi3tani3tatbe3lorri4or4reoit4esbe1libe5gu4itiarre4frre4cbe3giit3igbe3dii2tim2itio4itisrp4h4r3pet4itonr4peait5rybe3debe3dai5tudit3ul4itz_4be2dbeat3beak4ro4varo4tyros4sro5roiv5ioiv1itror3i5root1roomval1ub3berva5mo4izarva5piron4eban3ijac4qban4ebal1ajer5srom4prom4iba4geazz5i5judgay5alax4idax4ickais4aw4ly3awaya1vorav5ocav3igke5liv3el_ve4lov4elyro1feke4tyv4erdv4e2sa5vanav3ag5k2ick4illkilo5au1thk4in_4ves_ro3crkin4gve4teaun5dk5ishau4l2au3gu4kleyaugh3ve4tyk5nes1k2noat3ulkosh4at5uekro5n4k1s2at5uaat4that5te5vianat4sk5vidil4abolaci4l4adela3dylag4nlam3o3landrob3la4tosr4noular4glar3ilas4ea4topr3nivr3nita2tomr5nica4toglbin44l1c2vi5gnat3ifat1ica5tiar3neyr5net4ati_ld5isat4hol4driv2incle4bileft55leg_5leggr4nerr3nel4len_3lencr4nar1lentle3phle4prvin5dler4e3lergr3mitl4eroat5evr4mio5lesq3lessr3menl3eva4vingrma5cvio3lvi1ou4leyevi5rovi3so4l1g4vi3sulgar3l4gesate5cat5apli4agli2amr3lo4li4asr4lisli5bir4ligr2led4lics4vitil4icul3icyl3idaat5ac3lidirk4lel4iffli4flr3ket3lighvit3r4vityriv3iri2tulim3ili4moris4pl4inar3ishris4clin3ir4is_li5og4l4iqlis4pas1trl2it_as4shas5phri2pla4socask3ia3sicl3kallka4ta3sibl4lawashi4l5leal3lecl3legl3lel5riphas4abar2shrin4grin4ear4sarin4dr2inal5lowarre4l5met3rimol4modlmon42l1n2a3roorim5ilo4civo4la5rigil5ogo3loguri5et5longlon4iri1erlood5r4icolop3il3opmlora44ricir4icerib3a5los_v5oleri4agria4blos4tlo4taar2mi2loutar2izar3iolpa5bl3phal5phi4rhall3pit5voltar4im3volv2l1s2vom5ivori4l4siear4fllt5agar4fivo4rylten4vo4talth3ia3reeltis4ar4drw5ablrgo4naraw4lu3brluch4lu3cilu3enwag5olu5idlu4ma5lumia5raur5gitwait5luo3rw5al_luss4r5gisar4atl5venrgi4nara3pwar4tar3alwas4tly5mely3no2lys4l5ysewa1teaque5ma2car3gicma4clr3get5magnwed4nmaid54maldrg3erweet3wee5vwel4lapoc5re4whwest3ap3in4aphires2tr4es_mar3vre5rumas4emas1t5matemath3rero4r4eriap5atr1er4m5bilre1pumbi4vapar4a5nuran3ul4med_an3uare5lure1lian4twre5itmel4tan2trre4fy4antomen4are3fire2fe4menemen4imens4re1de3ment2r2edme5onre4awwin4g5reavme4tare3anme1tere1alm4etr3wiserdin4rdi4aan4stwith3an2span4snan2samid4amid4gan5otwl4esr4dalm4illmin4a3mindrcum3rc4itr3charcen4min4tm4inumiot4wl3ina3niumis5lan3ita3nip4mithan3ioan1gla3neuws4per2bina3nena5neem4ninw5s4tan1dl4mocrrbi4fmo2d1mo4gomois2xac5ex4agor4bagmo3mer4baba3narrau4ta5monrare4rar5cra5nor4aniam1inr2amiam5ifra4lomo3spmoth3m5ouf3mousam3icxer4ixe5roraf4tr5aclm3petra3bixhil5mpi4aam3ag3quetm5pirmp5is3quer2que_qua5vmpov5mp4tram5ab3alyz4m1s25alyt4alysa4ly_ali4exi5di5multx4ime4aldia4laral3adal5abak1enain5opu3trn4abu4nac_na4can5act5putexpe3dna4lia4i4n4naltai5lya3ic_pur4rag5ulnank4nar3c4narenar3inar4ln5arm3agognas4c4ag4l4ageupul3cage4oaga4na4gab3nautnav4e4n1b4ncar5ad5umn3chaa3ducptu4rpti3mnc1innc4itad4suad3owad4len4dain5dana5diua3ditndi4ba3dion1ditn3dizn5ducndu4rnd2we3yar4n3eara3dianeb3uac4um5neckac3ulp4siba3cio5negene4laac1inne5mine4moa3cie4nene4a2cine4poyc5erac1er2p1s2pro1tn2erepro3lner4rych4e2nes_4nesp2nest4neswpri4sycom4n5evea4carab3uln4gabn3gelpre3vpre3rycot4ng5han3gibng1inn5gitn4glangov4ng5shabi5an4gumy4erf4n1h4a5bannhab3a5bal3n4iani3anni4apni3bani4bl_us5ani5dini4erni2fip3petn5igr_ure3_un3up3per_un5op3pennin4g_un5k5nis_p5pel_un1en4ithp4ped_un1ani3tr_to4pympa3_til4n3ketnk3inyn5ic_se2ny4o5gy4onsnmet44n1n2_ru4d5pounnni4vnob4lpo4tan5ocly4ped_ro4qyper5noge4pos1s_ri4gpo4ry1p4or_res2no4mono3my_ree2po4ninon5ipoin2y4poc5po4gpo5em5pod_4noscnos4enos5tno5tayp2ta3noun_ra4cnowl3_pi2tyra5m_pi4eyr5ia_out3_oth32n1s2ns5ab_or3t_or1d_or3cplu4mnsid1nsig4y3s2eys3ion4socns4pen5spiploi4_odd5nta4bpli4n_ni4cn5tib4plignti2fpli3a3plannti4p1p2l23ysis2p3k2ys3ta_mis1nu5enpi2tun3uinp3ithysur4nu1men5umi3nu4nyt3icnu3trz5a2b_li4t_li3o_li2n_li4g_lev1_lep5_len4pion4oard3oas4e3pi1ooat5ip4inoo5barobe4l_la4mo2binpind4_ju3rob3ul_is4i_ir5rp4in_ocif3o4cil_in3so4codpi3lopi3enocre33piec5pidipi3dep5ida_in2kod3icodi3oo2do4odor3pi4cypian4_ine2o5engze3rooe4ta_im3m_id4l_hov5_hi3b_het3_hes3_go4r_gi4bpho4ro5geoo4gero3gie3phobog3it_gi5azo5ol3phizo4groogu5i4z1z22ogyn_fes3ohab5_eye55phieph1icoiff4_en3sph4ero3ing_en3go5ism_to2qans3v_el5d_eer4bbi4to3kenok5iebio5mo4lanper1v4chs_old1eol3erpe5ruo3letol4fi_du4co3liaper3op4ernp4erio5lilpe5ono5liop4encpe4la_do4tpee4do5livcin2q3pediolo4rol5pld3tabol3ub3pedeol3uno5lusedg1le1loaom5ahoma5l2p2edom2beom4bl_de3o3fich3pe4ao4met_co4ro3mia_co3ek3shao5midom1inll1fll3teapa2teo4monom3pi3pare_ca4tlue1pon4aco3nanm2an_pa4pum2en_on5doo3nenng1hoon4guon1ico3nioon1iso5niupa3nypan4ao3nou_bri2pain4ra1oronsu4rk1hopac4tpa4ceon5umonva5_ber4ood5eood5i6rks_oop3io3ordoost5rz1scope5dop1erpa4ca_ba4g_awn4_av4i_au1down5io3pito5pon1sync_as1s_as1p_as3ctch1c_ar5so5ra_ow3elo3visov4enore5auea1mor3eioun2d_ant4orew4or4guou5etou3blo5rilor1ino1rio_ang4o3riuor2miorn2eo5rofoto5sor5pe3orrhor4seo3tisorst4o3tif_an5cor4tyo5rum_al3tos3al_af1tos4ceo4teso4tano5scros2taos4poos4paz2z3wosi4ue3pai", "6": "os3ityos3itoz3ian_os4i4ey1stroos5tilos5titxquis3_am5atot3er_ot5erso3scopor3thyweek1noth3i4ot3ic_ot5icao3ticeor3thiors5enor3ougor3ityor3icaouch5i4o5ria_ani5mv1ativore5sho5realus2er__an3teover3sov4erttot3icoviti4o5v4olow3dero4r3agow5esto4posiop3ingo5phero5phanthy3sc3operaontif5on3t4ionten45paganp3agattele2gonspi4on3omyon4odipan3elpan4tyon3keyon5est3oncil_ar4tyswimm6par5diompro5par5elp4a4ripar4isomo4gepa5terst5scrpa5thy_atom5sta1tio5miniom3icaom3ic_ss3hatsky1scpear4lom3ena_ba5naol3umer1veilpedia4ped4icolli4er1treuo5liteol3ishpeli4epe4nano5lis_pen4thol3ingp4era_r1thoup4erago3li4f_bas4er1krauperme5ol5id_o3liceper3tio3lescolass4oi3terpe5tenpe5tiz_be5raoi5son_be3smphar5iphe3nooi5letph4es_oi3deroic3esph5ingr3ial_3ognizo5g2ly1o1gis3phone5phonio5geneo4gatora3mour2amenofit4tof5itera3chupi4ciepoly1eod5dedo5cureoc3ula1pole_5ocritpee2v1param4oc3raco4clamo3chetob5ingob3a3boast5eoke1st3nu3itpi5thanuf4fentu3meoerst2o3chasplas5tn3tinepli5ernti4ernter3sntre1pn4s3esplum4bnsati4npre4cns4moonon1eqnor5abpo3et5n5lessn5oniz5pointpoly5tnon4agnk3rup3nomicng1sprno5l4inois5i4n3o2dno3blenni3aln5keroppa5ran3itor3nitionis4ta5nine_ni3miznd3thrmu2dron3geripray4e5precipre5copre3emm3ma1bpre4lan5gerep3rese3press_can5cmedi2c5pri4e_ce4la3neticpris3op3rocal3chain4er5ipros3en4erarnera5bnel5iz_cit5rne4gatn5d2ifpt5a4bjanu3aign4itn3chisn5chiln5cheon4ces_nau3seid4iosna3talnas5tinan4itnanci4na5mitna5liahnau3zput3er2n1a2bhex2a3hatch1multi3hair1sm4pousg1utanmpo3rim4p1inmp5iesmphas4rach4empar5iraf5figriev1mpara5mo5seyram3et4mora_rane5oran4gemo3ny_monol4rap3er3raphymo3nizgno5morar5ef4raril1g2nacg1leadmoni3ara5vairav3elra5ziemon5gemon5etght1wemoi5sege3o1dmma5ryr5bine3fluoren1dixmis4ti_de3ra_de3rie3chasrch4err4ci4bm4inglm5ineedu2al_3miliame3tryrdi4er_des4crd3ingdi2rerme5thimet3alre5arr3mestim5ersadi2rende2ticdes3icre4cremen4temensu5re3disred5itre4facmen4dede2mosmen5acmem1o3reg3ismel5onm5e5dyme3died2d5ibren4te5mediare5pindd5a5bdata1bmba4t5cle4arma3tisma5scemar4lyre4spichs3huma5riz_dumb5re3strre4terbrus4qre3tribio1rhre5utiman3izre4valrev3elbi1orbbe2vie_eas3ire5vilba1thyman5is5maniamal4tymal4lima5linma3ligmag5inav3ioul5vet4rg3inglus3teanti1dl5umn_ltur3a_el3emltera4ltane5lp5ingloun5dans5gra2cabllos5etlor5ouric5aslo5rie_enam35ricidri4cie5lope_rid5erri3encri3ent_semi5lom3errig5an3logicril3iz5rimanlob5allm3ingrim4pell5out5rina__er4ril5linal2lin4l3le4tl3le4nriph5eliv3er_ge5og_han5k_hi3er_hon3olin3ea1l4inel4im4p_idol3_in3ci_la4cy_lath5rit3iclim4blrit5urriv5elriv3et4l4i4lli4gra_leg5elif3errk4linlid5er4lict_li4cor5licioli4atorl5ish_lig5a_mal5o_man5a_mer3c5less_rm5ersrm3ingy3thinle5sco3l4erilera5b5lene__mon3ele4matld4erild4erela4v4ar1nis44lativ_mo3rola5tanlan4telan5etlan4dllab3ic_mu5takin4dek3est_ro5filk3en4dro5ker5role__of5te4jestyys3icaron4al5izont_os4tlron4tai4v3ot_pe5tero3pelrop3ici5voreiv5il__pio5n_pre3mro4the_ran4tiv3en_rov5eliv3ellit3uati4tramr5pentrp5er__rit5ui4tismrp3ingit5ill_ros5tit3ica4i2tici5terirre4stit3era4ita5mita4bi_row5dist4lyis4ta_is4sesrsa5tiissen4is4sal_sci3erse4crrs5er_islan4rse5v2yo5netish5opis3honr4si4bis5han5iron_ir4minrtach4_self5iri3turten4diri5dei4rel4ire4de_sell5r4tieriq3uidrtil3irtil4lr4tilyr4tistiq5uefip4re4_sing4_ting4yn3chrru3e4lion3at2in4th_tin5krum3pli4no4cin3ityrun4ty_ton4aruti5nymbol5rvel4i_top5irv5er_r5vestin5geni5ness_tou5s_un3cein3cerincel45ryngei4n3auim3ulai5miniimi5lesac3riim5ida_ve5rasalar4ima5ryim3ageill5abil4istsan4deila5rai2l5am_wil5ii4ladeil3a4bsa5voright3iig3eraab5erd4ific_iff5enif5eroi3entiien5a45ie5gaidi5ou3s4cieab5latidi4arid5ianide3al4scopyab5rogid5ancic3ulaac5ardi2c5ocic3ipaic5inase2c3oi4carai4car_se4d4ei2b5riib5iteib5it_ib5ertib3eraac5aroi4ativ4ian4tse4molsen5ata5ceouh4warts5enedhus3t4s5enin4sentd4sentlsep3a34s1er_hun5kehu4min4servohro3poa5chethov5el5se5umhouse3sev3enho5senhort3eho5rishor5at3hol4ehol5arh5odizhlo3riac5robhis3elhion4ehimer4het4edsh5oldhe2s5ph5eroushort5here5aher4bahera3p3side_5sideshen5atsi5diz4signahel4lyact5ifhe3l4ihe5do55sine_h5ecathe4canad4dinsion5aad5er_har4lehard3e3sitioha5rasha3ranhan4tead3icahang5oadi4ersk5inesk5ing5hand_han4cyhan4cislith5hala3mh3ab4lsmall32g5y3n5gui5t3guard5smithad5ranaeri4eag5ellag3onia5guerso4labsol3d2so3licain5in4grada3s4on_gor5ougo5rizgondo5xpan4dait5ens5ophyal3end3g4o4ggnet4tglad5i5g4insgin5ge3g4in_spen4d2s5peog3imen5gies_3spher5giciagh5outsp5ingge5nizge4natge5lizge5lisgel4inxi5miz4gativgar5n4a5le5oga3nizgan5isga5mets5sengs4ses_fu4minfres5cfort5assi4erss5ilyfore5tfor5ayfo5ratal4ia_fon4dessur5aflo3ref5lessfis4tif1in3gstam4i5stands4ta4p5stat_fin2d5al5levs5tero4allicstew5afight5fi5del5ficie5ficiafi3cer5stickf3icena5log_st3ingf3icanama5ra5stockstom3a5stone2f3ic_3storef2f5iss4tradam5ascs4trays4tridf5fin_fend5efeath3fault5fa3thefar5thfam5is4fa4mafall5eew3inge5verbeven4ie5vengevel3oev3ellev5asteva2p5euti5let5roset3roget5rifsy5rinet3ricet5onaam5eraam5ilyami4noamor5ieti4noe5tidetai5loethod3eten4dtal5enes5urramp5enan3ageta5loge5strotan4detanta3ta5pere3ston4es2toes5times3tigta3rizestan43analy4taticta4tures4prean3arces3pertax4ises5onaes3olue5skintch5etanar4ies4i4ntead4ie2s5ima3natiande4sesh5enan3disan4dowang5iete5geres5ences5ecres5cana4n1icte2ma2tem3at3tenanwrita45erwau4tenesert3era3nieser3set5erniz4erniter4nis5ter3de4rivaan3i3fter3isan4imewo5vener3ineeri4ere3rient3ess_teth5e5ericke1ria4er3ester5esser3ent4erenea5nimier5enaer3emoth3easthe5atthe3iser5el_th5ic_th5icaere3in5thinkere5coth5odea5ninee3realan3ishan4klier4che5anniz4erandti4atoanoth5equi3lep5utat4ic1uan4scoe4probep3rehe4predans3poe4precan4surantal4e3penttim5ulep5anceo5rol3tine_eop3aran4tiewin4deap5eroen3ishen5icsen3etren5esten5esien5eroa3pheren3dicap3itae4nanten5amoem5ulaa3pituti3zen5emnize5missem5ishap5olaem5ine3tles_t5let_em1in2apor5iem3icaem5anael3op_el4labapos3te3liv3el5ishaps5esweath3e3lierel3icaar3actwa5verto3nate3libee4l1erel3egato3rietor5iza5radeelaxa4aran4gto3warelan4dej5udie5insttra5chtraci4ar5av4wa5gere5git5arbal4ar5easeg5ing4voteetrem5iar3enta5ressar5ial4tricsvor5abe3finetro5mitron5i4tronyar3iantro3sp5eficia3rieted5uloed3icae4d1erec3ulaec4tane4cremeco5roec3orae4concar5o5de4comme4cluse4clame5citeec5ifya5ronias3anta5sia_tu4nis2t3up_ecan5ce4belstur3ise4bel_eav3ene4a3tue5atifeath3ieat5eneart3eear4ilear4icear5eseam3ereal3oueal5erea5geread5iedum4be4ducts4duct_duc5eras3tenasur5adrea5rat3abl4d5outdo3natdom5izdo5lor4dlessu4bero3dles_at3alou3ble_d4is3tdirt5idi5niz3dine_at5ech5di3endi4cam1d4i3ad3ge4tud5estdev3ilde3strud3iedud3iesdes3tide2s5oat3egovis3itde4nardemor5at3en_uen4teuer4ilde5milat3eraugh3en3demicater5nuil5izdeli4ede5comde4cildecan4de4bonv3io4rdeb5it4dativ2d3a4bat3estu5laticu4tie5ulcheul3dercuss4icu5riaath5em3cultua5thenul3ingul5ishul4lar4vi4naul4liscu5ityctim3ic4ticuuls5esc5tantultra3ct5angcros4ecrop5ocro4pl5critiath5omum4blycre3at5vilitumor5oat5i5b5crat_cras5tcoro3ncop3iccom5ercol3orun5ishco3inc5clareat3ituunt3abat5ropun4tescit3iz4cisti4cista4cipicc5ing_cin3em3cinatuper5s5videsup3ingci2a5b5chini5videdupt5ib5vide_at4tag4ch1inch3ersch3er_ch5ene3chemiche5loure5atur4fercheap3vi5aliat3uravet3er4ch3abc5e4taau5sib3cessives4tece5ram2cen4e4cedenccou3turs5erur5tesur3theaut5enur4tiecav5al4cativave4nover3thcar5omca5percan4tycan3izcan5iscan4icus4lin3versecal4laver3ieca3latca5dencab3in3butiobuss4ebus5iebunt4iv4eresuten4i4u1t2iv3erenu3tineut3ingv4erelbroth35u5tizbound34b1orabon5at5vere_bom4bibol3icblun4t5blespblath5av3erav5enuebi3ogrbi5netven3om2v1a4bvac5ilbi3lizbet5izbe5strva5liebe5nigbbi4nabas4siva5nizbari4aav5ernbarbi5av5eryvel3liazi4eravi4er", "7": "_dri5v4ban5dagvar5iedbina5r43bi3tio3bit5ua_ad4derution5auti5lizver5encbuf4ferus5terevermi4ncall5incast5ercas5tigccompa5z3o1phros5itiv5chanicuri4fico5stati5chine_y5che3dupport54v3iden5cific_un4ter_at5omiz4oscopiotele4g5craticu4m3ingv3i3liz4c3retaul4li4bcul4tiscur5a4b4c5utiva5ternauiv4er_del5i5qdem5ic_de4monsdenti5fdern5izdi4latou4b5ingdrag5on5drupliuar5ant5a5si4tec5essawo4k1enec5ifiee4compear5inate4f3eretro5phewide5sp5triciatri5cesefor5ese4fuse_oth5esiar5dinear4chantra5ventrac4tetrac4itar5ativa5ratioel5ativor5est_ar5adisel5ebraton4alie4l5ic_wea5rieel5igibe4l3ingto5cratem5igraem3i3niemoni5oench4erwave1g4a4pillavoice1ption5eewill5inent5age4enthesvaude3vtill5inep5recaep5ti5bva6guer4erati_tho5rizthor5it5thodicer5ence5ternitteri5zater5iesten4tage4sage_e4sagese4sert_an5est_e4sertse4servaes5idenes5ignaesis4tees5piraes4si4btal4lisestruc5e5titioounc5erxe4cutota5bleset5itiva4m5atoa4matis5stratu4f3ical5a5lyst4ficatefill5instern5isspend4gani5zasqual4la4lenti4g3o3nas5ophiz5sophicxpecto55graph_or5angeuri4al_4graphy4gress_smol5d4hang5erh5a5nizharp5enhar5terhel4lishith5erhro5niziam5eteia4tricic4t3uascour5au2r1al_5scin4dover4nescan4t55sa3tiou5do3ny_ven4de_under5ty2p5al_anti5sylla5bliner4arturn3ari5nite_5initioinsur5aion4eryiphras4_tim5o5_ten5an_sta5blrtroph4_se5rieiq3ui3t5i5r2izis5itiviso5mer4istral5i5ticki2t5o5mtsch3ie_re5mittro3fiti4v3er_i4vers_ros5per_pe5titiv3o3ro_ped5alro5n4is_or5ato4jestierom5ete_muta5bk5iness4latelitr4ial__mist5i_me5terr4ming_lev4er__mar5tilev4eralev4ers_mag5a5liar5iz5ligaterit5ers_lat5errit5er_r5ited__im5pinri3ta3blink5er_hon5ey5litica_hero5ior5aliz_hand5irip5lic_gen3t4tolo2gylloqui5_con5grt1li2erbad5ger4operag_eu4lertho3donter2ic__ar4tie_ge4ome_ge5ot1_he3mo1_he3p6a_he3roe_in5u2tpara5bl5tar2rht1a1mintalk1a5ta3gon_par5age_aster5_ne6o3f_noe1thstyl1is_poly1s5pathic_pre1ampa4tricl3o3niz_sem4ic_semid6_semip4_semir45ommend_semiv4lea4s1a_spin1oom5etryspher1o_to6poglo4ratospe3cio3s2paceso2lute_we2b1l_re1e4ca5bolicom5erseaf6fishside5swanal6ysano5a2cside5stl5ties_5lumniasid2ed_anti1reshoe1stscy4th1s4chitzsales5wsales3cat6tes_augh4tlau5li5fom5atizol5ogizo5litiorev5olure5vertre5versbi5d2ifbil2lab_earth5pera5blro1tronro3meshblan2d1blin2d1blon2d2bor1no5ro1bot1re4ti4zr5le5quperi5stper4malbut2ed_but4tedcad5e1moist5enre5stalress5ibchie5vocig3a3roint5er4matizariv1o1lcous2ticri3tie5phisti_be5stoog5ativo2g5a5rr3a3digm4b3ingre4posir4en4tade4als_od5uctsquasis6quasir6re5fer_p5trol3rec5olldic1aiddif5fra3pseu2dr5ebrat5metric2d1lead2d1li2epro2g1epre1neuod5uct_octor5apoin3came5triem5i5liepli5narpara3memin5glim5inglypi4grappal6matmis4er_m5istryeo3graporth1riop1ism__but4tio3normaonom1icfeb1ruafermi1o_de4moio5a5lesodit1icodel3lirb5ing_gen2cy_n4t3ingmo5lestration4get2ic_4g1lishobli2g1mon4ismnsta5blmon4istg2n1or_nov3el3ns5ceivno1vembmpa5rabno4rarymula5r4nom1a6lput4tinput4tedn5o5miz_cam4penag5er_nge5nesh2t1eoun1dieck2ne1skiifac1etncour5ane3backmono1s6mono3chmol1e5cpref5ac3militapre5tenith5i2lnge4n4end5est__capa5bje1re1mma1la1ply5styr1kovian_car5olprin4t3lo2ges_l2l3ishprof5it1s2tamp", "8": "lead6er_url5ing_ces5si5bch5a5nis1le1noidlith1o5g_chill5ilar5ce1nym5e5trych5inessation5arload4ed_load6er_la4c3i5elth5i2lyneg5ativ1lunk3erwrit6er_wrap3arotrav5es51ke6linga5rameteman3u1scmar1gin1ap5illar5tisticamedio6c1me3gran3i1tesima3mi3da5bves1titemil2l1agv1er1eigmi6n3is_1verely_e4q3ui3s5tabolizg5rapher5graphicmo5e2lasinfra1s2mon4ey1lim3ped3amo4no1enab5o5liz_cor5nermoth4et2m1ou3sinm5shack2ppo5sitemul2ti5uab5it5abimenta5rignit1ernato5mizhypo1thani5ficatuad1ratu4n5i4an_ho6r1ic_ua3drati5nologishite3sidin5dling_trib5utin5glingnom5e1non1o1mistmpos5itenon1i4so_re5stattro1p2istrof4ic_g2norespgnet1ism5glo5binlem5aticflow2er_fla1g6elntrol5lifit5ted_treach1etra1versl5i5ticso3mecha6_for5mer_de5rivati2n3o1me3spac6i2t3i4an_thy4l1antho1k2er_eq5ui5to4s3phertha4l1amt3ess2es3ter1geiou3ba3dotele1r6ooxi6d1iceli2t1isonspir5apar4a1leed1ulingea4n3iesoc5ratiztch3i1er_kil2n3ipi2c1a3dpli2c1abt6ap6athdrom3e5d_le6icesdrif2t1a_me4ga1l1prema3cdren1a5lpres2plipro2cess_met4ala3do5word1syth3i2_non1e2m_post1ampto3mat4rec5ompepu5bes5cstrib5utqu6a3si31stor1ab_sem6is4star3tliqui3v4arr1abolic_sph6in1de5clar12d3aloneradi1o6gs3qui3tosports3wsports3cra5n2hascro5e2cor3bin1gespokes5wspi2c1il_te3legrcroc1o1d_un3at5t_dictio5cat1a1s2buss4ingbus6i2esbus6i2erbo2t1u1lro5e2las1s2pacinb1i3tivema5rine_r3pau5li_un5err5r5ev5er__vi2c3arback2er_ma5chinesi5resid5losophyan3ti1n2sca6p1ersca2t1olar2rangesep3temb1sci2uttse3mes1tar3che5tsem1a1ph", "9": "re4t1ribuuto5maticl3chil6d1a4pe5able1lec3ta6bas5ymptotyes5ter1yl5mo3nell5losophizlo1bot1o1c5laratioba6r1onierse1rad1iro5epide1co6ph1o3nscrap4er_rec5t6angre2c3i1prlai6n3ess1lum5bia_3lyg1a1miec5ificatef5i5nites2s3i4an_1ki5neticjapan1e2smed3i3cinirre6v3ocde2c5linao3les3termil5li5listrat1a1gquain2t1eep5etitiostu1pi4d1v1oir5du1su2per1e6_mi1s4ers3di1methy_mim5i2c1i5nitely_5maph1ro15moc1ra1tmoro6n5isdu1op1o1l_ko6r1te1n3ar4chs_phi2l3ant_ga4s1om1teach4er_parag6ra4o6v3i4an_oth3e1o1sn3ch2es1to5tes3toro5test1eror5tively5nop5o5liha2p3ar5rttrib1ut1_eth1y6l1e2r3i4an_5nop1oly_graph5er_5eu2clid1o1lo3n4omtrai3tor1_ratio5na5mocratiz_rav5en1o", "10": "se1mi6t5ic3tro1le1um5sa3par5iloli3gop1o1am1en3ta5bath3er1o1s3slova1kia3s2og1a1myo3no2t1o3nc2tro3me6c1cu2r1ance5noc3er1osth1o5gen1ih3i5pel1a4nfi6n3ites_ever5si5bs2s1a3chu1d1ri3pleg5_ta5pes1trproc3i3ty_s5sign5a3b3rab1o1loiitin5er5arwaste3w6a2mi1n2ut1erde3fin3itiquin5tes5svi1vip3a3r", "11": "pseu3d6o3f2s2t1ant5shimi1n2ut1estpseu3d6o3d25tab1o1lismpo3lyph1onophi5lat1e3ltravers3a3bschro1ding12g1o4n3i1zat1ro1pol3it3trop1o5lis3trop1o5lesle3g6en2dreeth1y6l1eneor4tho3ni4t", "12": "3ra4m5e1triz1e6p3i3neph1" } });

  // ../Web/preview-engine/src/render/hyphenate.js
  var table = null;
  function patterns() {
    if (table) return table;
    table = /* @__PURE__ */ new Map();
    for (const [length, packed] of Object.entries(hyphenationPatterns.patterns)) {
      const size = Number(length);
      for (let index = 0; index < packed.length; index += size) {
        const pattern = packed.slice(index, index + size);
        const letters = pattern.replace(/\d/g, "");
        const values = new Array(letters.length + 1).fill(0);
        let position = 0;
        for (const character of pattern) {
          if (/\d/.test(character)) values[position] = Number(character);
          else position += 1;
        }
        table.set(letters, values);
      }
    }
    return table;
  }
  function hyphenationPoints(word) {
    const { leftmin } = hyphenationPatterns;
    const rightmin = 2;
    if (!/^[A-Za-z]+$/.test(word) || word.length < leftmin + rightmin) return [];
    const text = `_${word.toLowerCase()}_`;
    const scores = new Array(text.length + 1).fill(0);
    const known = patterns();
    for (let start = 0; start < text.length; start += 1) {
      for (let end = start + 1; end <= text.length; end += 1) {
        const values = known.get(text.slice(start, end));
        if (!values) continue;
        values.forEach((value, offset) => {
          if (value > scores[start + offset]) scores[start + offset] = value;
        });
      }
    }
    const points = /* @__PURE__ */ new Set();
    for (let index = leftmin; index <= word.length - rightmin; index += 1) if (scores[index + 1] % 2 === 1) points.add(index);
    for (let index = leftmin; index <= word.length - rightmin; index += 1) if (/[a-z]/.test(word[index - 1]) && /[A-Z]/.test(word[index])) points.add(index);
    return [...points].sort((a2, b) => a2 - b);
  }

  // ../Web/preview-engine/src/render/layout.js
  var sub = (value, amount) => value === null || value === Infinity ? value : Math.max(0, value - amount);
  var snap = (value) => Math.ceil(value * 2 - 1e-6) / 2;
  var Node = class {
    constructor() {
      this.frame = { x: 0, y: 0, width: 0, height: 0 };
    }
    size() {
      return [0, 0];
    }
    place(x, y, width, height) {
      this.frame = { x, y, width, height };
    }
    edge() {
      return null;
    }
  };
  var cjk = /[\u2e80-\u9fff\uac00-\ud7af\uf900-\ufaff\uff00-\uffef]/u;
  var emojiCluster = /(\p{Extended_Pictographic}(?:\uFE0F|\u200D\p{Extended_Pictographic}|[\u{1F3FB}-\u{1F3FF}])*\uFE0F?|[\u{1F1E6}-\u{1F1FF}]{2})/u;
  function breakUnits(paragraph) {
    const units = [];
    for (const word of paragraph.split(/ +/).filter(Boolean)) {
      const byEmoji = emojiCluster.test(word) ? word.split(emojiCluster).filter(Boolean) : [word];
      const pieces = byEmoji.flatMap((part) => cjk.test(part) ? part.split(/(?=[\u2e80-\u9fff\uac00-\ud7af\uf900-\ufaff])/u).filter(Boolean) : [part]);
      pieces.forEach((piece, index) => {
        const separator = index === 0 ? " " : "";
        if (units.length && /^[:;,.!?)\]}%，。！？、：；）」』]/.test(piece)) units[units.length - 1].text += separator + piece;
        else units.push({ text: piece, separator });
      });
    }
    return units;
  }
  var joinUnits = (line) => line.map((unit, index) => index === 0 ? unit.text : unit.separator + unit.text).join("");
  var TextNode = class extends Node {
    constructor(text, style, measurer) {
      super();
      this.text = text;
      this.style = style;
      this.measurer = measurer;
    }
    /// When every word fits, the standard line break strategy may push a word
    /// down (see pushOut). A word wider than the line breaks between
    /// characters, as the browser does, except that iOS text styles (Dynamic
    /// Type fonts, style.hyphenate) hyphenate it at the longest dictionary
    /// break that fits ("Depar- / ture gate").
    displayText(width) {
      if (width === null || width === Infinity || width <= 0) return this.text;
      const key = `${width}`;
      this.hyphenated ??= /* @__PURE__ */ new Map();
      if (this.hyphenated.has(key)) return this.hyphenated.get(key);
      const broken = this.text.split("\n").map((paragraph) => this.pushOut(paragraph, width)).join("\n");
      const pushed = broken.replace(/ (?=[:;!?%)\]}，。！？、：；）」』])/g, " ");
      if (this.style.hyphenate === false || broken !== this.text) {
        this.hyphenated.set(key, pushed);
        return pushed;
      }
      const fits = (piece) => this.measurer.measure(piece, this.style, null).width <= width + 0.01;
      const result = pushed.replace(/[^\s]+/g, (word) => {
        if (fits(word)) return word;
        const [, lead, core, tail] = /^([^A-Za-z]*)([A-Za-z]*)(.*)$/s.exec(word);
        const points = hyphenationPoints(core).map((point) => point + lead.length);
        const pieces = [];
        let rest = word;
        let consumed = 0;
        while (!fits(rest)) {
          const point = points.filter((value) => value > consumed && value < consumed + rest.length && fits(`${word.slice(consumed, value)}-`)).at(-1);
          if (point === void 0) break;
          pieces.push(`${word.slice(consumed, point)}-`);
          rest = word.slice(point);
          consumed = point;
        }
        pieces.push(rest);
        return tail === void 0 ? word : pieces.join("\n");
      });
      this.hyphenated.set(key, result);
      return result;
    }
    /// The standard line break strategy (UIKit and AppKit) pushes a word down
    /// when a two-line paragraph would end in a single word ("October /
    /// 18, 2026"), unless that leaves the first line under 55% as wide as the
    /// new last line ("Hello from / GitHub" stays). Breaks before punctuation
    /// are not allowed (UAX #14), so "Size :" stays together. This matches
    /// TextKit's .standard strategy in 24,420 of 24,441 width/size/weight
    /// cases (Tools/ScriptWidgetPreview/Scripts/line-break-sweep.swift).
    pushOut(paragraph, width) {
      const words = breakUnits(paragraph);
      const join = joinUnits;
      const measure = (line) => this.measurer.measure(join(line), this.style, null).width;
      const fits = (line) => measure(line) <= width + 0.01;
      if (words.length < 3 || fits(words) || !words.every((word) => fits([word]))) return paragraph;
      const lines = [[]];
      for (const word of words) {
        const line = lines.at(-1);
        if (!line.length || fits([...line, word])) line.push(word);
        else lines.push([word]);
      }
      if (lines.length !== 2) return paragraph;
      const [first, last] = lines;
      if (last.length !== 1 || last[0].text.includes(" ") || first.length < 2) return paragraph;
      const moved = [first.at(-1), ...last];
      const rest = first.slice(0, -1);
      if (!fits(moved) || measure(rest) < measure(moved) * 0.55) return paragraph;
      return `${join(rest)}
${join(moved)}`;
    }
    /// SwiftUI keeps breaking a word one character per line in a column
    /// narrower than "…" as long as its first character fits.
    /// Whether a height proposal leaves room for a single line only.
    oneLine(ph) {
      return ph !== null && ph !== Infinity && ph < this.style.natural + this.style.leading - 1e-6;
    }
    wrapsCharacters(width) {
      const first = [...this.text.trim()][0];
      return first !== void 0 && this.measurer.measure(first, this.style, null).width <= width + 0.01;
    }
    /// The lines drawn at `width`: explicit breaks from displayText, then
    /// greedy breaking by units; a unit wider than the line breaks between
    /// characters.
    breakLines(width) {
      const fits = (value) => this.measurer.measure(value, this.style, null).width <= width + 0.01;
      const lines = [];
      for (const paragraph of this.displayText(width).split("\n")) {
        let line = [];
        for (const unit of breakUnits(paragraph)) {
          if (fits(joinUnits([...line, unit]))) {
            line.push(unit);
            continue;
          }
          if (line.length) lines.push(joinUnits(line));
          line = [];
          let piece = "";
          for (const character of [...unit.text]) {
            if (piece && !fits(piece + character)) {
              lines.push(piece);
              piece = character;
            } else piece += character;
          }
          line = [{ text: piece, separator: unit.separator }];
        }
        lines.push(joinUnits(line));
      }
      return lines;
    }
    /// The longest prefix that fits with "…", cut mid-word, with trailing
    /// spaces dropped ("Hello fr…", "Travel…"). Runs of spaces are kept, as
    /// CoreText keeps them.
    ellipsize(value, width) {
      const characters = [...value.replace(/\n/g, " ")];
      const fits = (count) => this.truncatedWidth(characters, count) <= width + 0.01;
      let low = 0;
      let high = characters.length;
      while (low < high) {
        const middle = Math.ceil((low + high) / 2);
        if (fits(middle)) low = middle;
        else high = middle - 1;
      }
      return `${characters.slice(0, low).join("").trimEnd()}…`;
    }
    /// Width CoreText draws for the first `count` characters plus "…": the
    /// prefix keeps its advance from the full string (kerning against the next
    /// character included) and the ellipsis is not kerned with it, so "07…"
    /// cut from "07:00 AM" is wider than "07…" measured alone.
    truncatedWidth(characters, count) {
      const prefix = characters.slice(0, count).join("").trimEnd();
      const length = [...prefix].length;
      const next = characters[length];
      const measure = (value) => this.measurer.measure(value, this.style, null).width;
      const advance = next === void 0 || next === " " || prefix === "" ? measure(prefix) : measure(prefix + next) - measure(next);
      return advance + this.measurer.ellipsisWidth(this.style);
    }
    /// SwiftUI truncation to `count` lines: earlier lines stay as broken, the
    /// rest is cut mid-word with "…", and the text reports the widest drawn
    /// line (not the offered width).
    truncate(width, count) {
      const lines = this.breakLines(width);
      if (lines.length <= count) return null;
      const kept = lines.slice(0, count - 1);
      let position = 0;
      for (const line of kept) {
        for (const character of line.replace(/-$/, "")) {
          while (position < this.text.length && /\s/.test(this.text[position]) && !/\s/.test(character)) position += 1;
          if (this.text.startsWith(character, position)) position += character.length;
          else if (character === " " && this.text[position] === " ") position += 1;
        }
      }
      const rest = this.text.slice(position).trimStart();
      const last = this.ellipsize(rest, width);
      const drawn = [...kept, last];
      const restCharacters = [...rest.replace(/\n/g, " ")];
      const lastWidth = this.truncatedWidth(restCharacters, [...last].length - 1);
      return { text: drawn.join("\n"), width: Math.max(lastWidth, ...kept.map((line) => this.measurer.measure(line, this.style, null).width)) };
    }
    metrics(width) {
      return this.measurer.measure(width === null ? this.text : this.displayText(width), this.style, width);
    }
    layout(pw, ph) {
      const { natural, leading } = this.style;
      if (this.text === "") return { width: 0, height: 0, lines: 0, total: 0 };
      let width;
      let lines;
      if (pw !== null && pw <= 0.01) return { width: 0, height: natural, lines: 1, total: 1, text: "" };
      if (pw === null || pw === Infinity) {
        const m = this.metrics(null);
        width = m.width;
        lines = m.lines;
      } else if (pw < this.measurer.ellipsisWidth(this.style) && (this.oneLine(ph) || !this.wrapsCharacters(pw))) {
        const text2 = this.text.trim() === "" ? "" : this.oneLine(ph) ? this.text.split("\n")[0] : "…";
        return { width: snap(pw), height: natural, lines: 1, total: 1, text: text2, clip: true };
      } else {
        const free = this.metrics(null);
        if (pw >= free.width - 0.01) {
          width = free.width;
          lines = free.lines;
        } else {
          const m = this.metrics(pw);
          width = Math.min(pw, m.width);
          lines = m.lines;
        }
      }
      const total = lines;
      if (ph !== null && ph !== Infinity) lines = Math.min(lines, Math.max(1, Math.floor((ph - natural) / leading + 1e-6) + 1));
      let text = null;
      if (lines < total && pw !== null && pw !== Infinity && pw >= this.measurer.ellipsisWidth(this.style)) {
        const truncated = this.truncate(pw, lines);
        if (truncated) {
          text = truncated.text;
          width = truncated.width;
        }
      }
      return { width: snap(width), height: natural + (lines - 1) * leading, lines, total, text };
    }
    size(pw, ph) {
      const { width, height } = this.layout(pw, ph);
      return [width, height];
    }
    place(x, y, width, height) {
      super.place(x, y, width, height);
      this.lines = this.layout(width, height);
    }
    edge() {
      return this.style;
    }
  };
  var FlexibleNode = class extends Node {
    constructor(ideal = [10, 10]) {
      super();
      this.ideal = ideal;
    }
    size(pw, ph) {
      return [pw ?? this.ideal[0], ph ?? this.ideal[1]];
    }
  };
  var FixedNode = class extends Node {
    constructor(width, height) {
      super();
      this.width = width;
      this.height = height;
    }
    size() {
      return [this.width, this.height];
    }
  };
  var SpacerNode = class extends Node {
    constructor(axis, minLength = 8) {
      super();
      this.axis = axis;
      this.minLength = minLength;
      this.isSpacer = true;
    }
    size(pw, ph) {
      const along = (proposal) => proposal === null ? this.minLength : Math.max(this.minLength, proposal);
      if (this.axis === "h") return [along(pw), 0];
      if (this.axis === "v") return [0, along(ph)];
      return [along(pw), along(ph)];
    }
  };
  var AspectNode = class extends Node {
    constructor(natural, ratio, mode) {
      super();
      this.natural = natural;
      this.ratio = ratio ?? natural[0] / Math.max(natural[1], 1e-9);
      this.mode = mode;
    }
    size(pw, ph) {
      if (pw === null && ph === null) return this.natural;
      const w = pw ?? (ph === null || ph === Infinity ? this.natural[0] : ph * this.ratio);
      const h = ph ?? (pw === null || pw === Infinity ? this.natural[1] : pw / this.ratio);
      if (w === Infinity || h === Infinity) return [w === Infinity ? h === Infinity ? Infinity : h * this.ratio : w, h === Infinity ? w === Infinity ? Infinity : w / this.ratio : h];
      const fitWidth = Math.min(w, h * this.ratio);
      const fillWidth = Math.max(w, h * this.ratio);
      const width = this.mode === "fill" ? fillWidth : fitWidth;
      return [width, width / this.ratio];
    }
  };
  var placementOffer = (final, proposed) => proposed !== null && proposed !== void 0 && proposed !== Infinity && proposed > final ? proposed : final;
  var PaddingNode = class extends Node {
    constructor(child, [top, trailing, bottom, leading]) {
      super();
      this.child = child;
      this.insets = { top, trailing, bottom, leading };
    }
    size(pw, ph) {
      this.proposal = [pw, ph];
      const { top, trailing, bottom, leading } = this.insets;
      const [w, h] = this.child.size(sub(pw, leading + trailing), sub(ph, top + bottom));
      return [w + leading + trailing, h + top + bottom];
    }
    place(x, y, width, height) {
      super.place(x, y, width, height);
      const { top, trailing, bottom, leading } = this.insets;
      const innerW = Math.max(0, width - leading - trailing);
      const innerH = Math.max(0, height - top - bottom);
      const [pw, ph] = this.proposal ?? [width, height];
      const [w, h] = this.child.size(placementOffer(innerW, sub(pw, leading + trailing)), placementOffer(innerH, sub(ph, top + bottom)));
      this.child.place(leading + (innerW - w) / 2, top + (innerH - h) / 2, w, h);
    }
  };
  var alignOffset = (space, size, where) => where === "start" ? 0 : where === "end" ? space - size : (space - size) / 2;
  var FrameNode = class extends Node {
    constructor(child, { mode, width, height, alignment }) {
      super();
      this.child = child;
      this.mode = mode;
      this.width = width;
      this.height = height;
      this.alignment = alignment;
    }
    size(pw, ph) {
      this.proposal = [pw, ph];
      if (this.mode === "max") {
        const [cw2, ch2] = this.child.size(pw, ph);
        return [pw === null ? cw2 : pw, ph === null ? ch2 : ph];
      }
      const fixedW = this.mode === "size" || this.mode === "width" ? this.width : null;
      const fixedH = this.mode === "size" || this.mode === "height" ? this.height : null;
      const [cw, ch] = this.child.size(fixedW ?? pw, fixedH ?? ph);
      return [fixedW ?? cw, fixedH ?? ch];
    }
    place(x, y, width, height) {
      super.place(x, y, width, height);
      const [pw, ph] = this.proposal ?? [width, height];
      const fixedW = this.mode === "size" || this.mode === "width";
      const fixedH = this.mode === "size" || this.mode === "height";
      const [w, h] = this.child.size(fixedW ? width : placementOffer(width, pw), fixedH ? height : placementOffer(height, ph));
      const [horizontal, vertical] = this.alignment;
      this.child.place(alignOffset(width, w, horizontal), alignOffset(height, h, vertical), w, h);
    }
  };
  var DecorationNode = class extends Node {
    constructor(child, decoration) {
      super();
      this.child = child;
      this.decoration = decoration;
    }
    size(pw, ph) {
      return this.child.size(pw, ph);
    }
    place(x, y, width, height) {
      super.place(x, y, width, height);
      this.child.place(0, 0, width, height);
    }
    edge(side) {
      return this.decoration.keepsEdges ? this.child.edge(side) : null;
    }
  };
  var StackNode = class extends Node {
    constructor(axis, children, { alignment, spacing }) {
      super();
      this.axis = axis;
      this.children = children;
      this.alignment = alignment;
      this.spacing = children.map((child, index) => index === 0 ? 0 : spacing(children[index - 1], child));
    }
    along(size) {
      return this.axis === "h" ? size[0] : size[1];
    }
    cross(size) {
      return this.axis === "h" ? size[1] : size[0];
    }
    propose(child, along, cross) {
      return this.axis === "h" ? child.size(along, cross) : child.size(cross, along);
    }
    // Spacers only take what is left: reserve their minimum lengths, share the
    // rest among the other children (least flexible first), then split the
    // leftover between spacers.
    allocate(pAlong, pCross) {
      const gaps = this.spacing.reduce((sum, value) => sum + value, 0);
      if (pAlong === null || pAlong === Infinity) return this.children.map((child) => this.propose(child, pAlong, pCross));
      const spacers = this.children.map((child) => child.isSpacer === true);
      const reserved = this.children.reduce((sum, child, index) => sum + (spacers[index] ? child.minLength : 0), 0);
      const order = this.children.map((child, index) => ({ child, index })).filter(({ index }) => !spacers[index]).map(({ child, index }) => {
        const min = this.along(this.propose(child, 0, pCross));
        const max = this.along(this.propose(child, Infinity, pCross));
        return { index, flexibility: max - min };
      }).sort((a2, b) => a2.flexibility - b.flexibility || a2.index - b.index);
      let remaining = pAlong - gaps - reserved;
      let count = order.length;
      const sizes = new Array(this.children.length);
      for (const { index } of order) {
        const offer = Math.max(0, remaining / count);
        sizes[index] = this.propose(this.children[index], offer, pCross);
        remaining -= this.along(sizes[index]);
        count -= 1;
      }
      const spacerCount = spacers.filter(Boolean).length;
      const leftover = Math.max(0, remaining + reserved);
      this.children.forEach((child, index) => {
        if (spacers[index]) sizes[index] = this.propose(child, Math.max(child.minLength, leftover / spacerCount), pCross);
      });
      return sizes;
    }
    size(pw, ph) {
      this.proposal = [pw, ph];
      const pAlong = this.axis === "h" ? pw : ph;
      const pCross = this.axis === "h" ? ph : pw;
      const sizes = this.allocate(pAlong, pCross);
      const along = sizes.reduce((sum, size) => sum + this.along(size), 0) + this.spacing.reduce((sum, value) => sum + value, 0);
      const cross = sizes.reduce((max, size) => Math.max(max, this.cross(size)), 0);
      return this.axis === "h" ? [along, cross] : [cross, along];
    }
    place(x, y, width, height) {
      super.place(x, y, width, height);
      const [pw, ph] = this.proposal ?? [width, height];
      const proposedAlong = this.axis === "h" ? pw : ph;
      const proposedCross = this.axis === "h" ? ph : pw;
      const finalCross = this.axis === "h" ? height : width;
      const rigid = (limit) => this.children.some((child) => this.cross(this.propose(child, null, 0)) > limit + 0.01);
      const pAlong = proposedAlong;
      const offered = proposedCross !== null && proposedCross !== Infinity;
      const pCross = offered && (finalCross < proposedCross - 0.01 || finalCross > proposedCross + 0.01 && rigid(proposedCross)) ? proposedCross : finalCross;
      const sizes = this.allocate(pAlong, pCross);
      let cursor = 0;
      this.children.forEach((child, index) => {
        cursor += this.spacing[index];
        const size = sizes[index];
        const offset = alignOffset(this.axis === "h" ? height : width, this.cross(size), this.alignment);
        if (this.axis === "h") child.place(cursor, offset, size[0], size[1]);
        else child.place(offset, cursor, size[0], size[1]);
        cursor += this.along(size);
      });
    }
    // Spacing preferences: a VStack exposes its first/last child; an HStack
    // merges its children (the largest text edge wins).
    edge(side) {
      if (this.children.length === 0) return null;
      if (this.axis === "v") return side === "top" ? this.children[0].edge("top") : this.children.at(-1).edge("bottom");
      return mergedEdge(this.children, side);
    }
  };
  function mergedEdge(children, side) {
    const edges = children.map((child) => child.edge(side)).filter(Boolean);
    const text = edges.filter((edge) => !edge.symbol);
    return (text.length ? text : edges).reduce((best, edge) => !best || edge.size > best.size ? edge : best, null);
  }
  var ZStackNode = class extends Node {
    constructor(children) {
      super();
      this.children = children;
    }
    edge(side) {
      return mergedEdge(this.children, side);
    }
    size(pw, ph) {
      return this.children.map((child) => child.size(pw, ph)).reduce(([w, h], [cw, ch]) => [Math.max(w, cw), Math.max(h, ch)], [0, 0]);
    }
    place(x, y, width, height) {
      super.place(x, y, width, height);
      for (const child of this.children) {
        const [w, h] = child.size(width, height);
        child.place((width - w) / 2, (height - h) / 2, w, h);
      }
    }
  };
  var GridNode = class extends Node {
    constructor(axis, children, { items, spacing, alignment }) {
      super();
      this.axis = axis;
      this.children = children;
      this.items = items;
      this.spacing = spacing;
      this.alignment = alignment;
      this.trackSpacing = 8;
    }
    tracks(available) {
      const spacing = this.trackSpacing;
      const fixed = this.items.filter((item) => item.type === "fixed").reduce((sum, item) => sum + item.value, 0);
      const flexibleCount = this.items.filter((item) => item.type !== "fixed").length;
      const free = Math.max(0, available - fixed - spacing * Math.max(0, this.items.length - 1));
      const tracks = [];
      for (const item of this.items) {
        if (item.type === "fixed") tracks.push(item.value);
        else if (item.type === "adaptive") {
          const share = flexibleCount ? free / flexibleCount : free;
          const count = Math.max(1, Math.floor((share + spacing) / (item.min + spacing)));
          const size = Math.min(item.max ?? Infinity, (share - spacing * (count - 1)) / count);
          for (let index = 0; index < count; index += 1) tracks.push(Math.max(item.min, size));
        } else tracks.push(flexibleCount ? free / flexibleCount : free);
      }
      return tracks;
    }
    arrange(pAlong) {
      const available = pAlong === null || pAlong === Infinity ? this.items.length * 60 : pAlong;
      const tracks = this.tracks(available);
      const lines = [];
      this.children.forEach((child, index) => {
        const line = Math.floor(index / tracks.length);
        const track = index % tracks.length;
        const size = this.axis === "v" ? child.size(tracks[track], null) : child.size(null, tracks[track]);
        (lines[line] ??= []).push({ child, track, size });
      });
      const extents = lines.map((line) => Math.max(...line.map(({ size }) => this.axis === "v" ? size[1] : size[0])));
      return { tracks, lines, extents };
    }
    size(pw, ph) {
      const { tracks, extents } = this.arrange(this.axis === "v" ? pw : ph);
      const along = tracks.reduce((sum, value) => sum + value, 0) + this.trackSpacing * Math.max(0, tracks.length - 1);
      const cross = extents.reduce((sum, value) => sum + value, 0) + this.spacing * Math.max(0, extents.length - 1);
      const width = this.axis === "v" ? pw === null || pw === Infinity ? along : pw : cross;
      const height = this.axis === "v" ? cross : ph === null || ph === Infinity ? along : ph;
      return [width, height];
    }
    place(x, y, width, height) {
      super.place(x, y, width, height);
      const { tracks, lines, extents } = this.arrange(this.axis === "v" ? width : height);
      const total = tracks.reduce((sum, value) => sum + value, 0) + this.trackSpacing * Math.max(0, tracks.length - 1);
      const start = ((this.axis === "v" ? width : height) - total) / 2;
      let lineOffset = 0;
      lines.forEach((line, lineIndex) => {
        for (const { child, track, size } of line) {
          const trackOffset = start + tracks.slice(0, track).reduce((sum, value) => sum + value, 0) + this.trackSpacing * track;
          if (this.axis === "v") child.place(trackOffset + (tracks[track] - size[0]) / 2, lineOffset + (extents[lineIndex] - size[1]) / 2, size[0], size[1]);
          else child.place(lineOffset + (extents[lineIndex] - size[0]) / 2, trackOffset + (tracks[track] - size[1]) / 2, size[0], size[1]);
        }
        lineOffset += extents[lineIndex] + this.spacing;
      });
    }
  };
  var emojiAdvances = [1, 3, 4, 6, 7, 9, 10, 12, 13, 14, 16, 17, 19, 20, 21, 23, 23, 24, 24, 25, 26, 26, 27, 27, 28, 30, 31, 32, 33, 34, 35, 36, 37, 38, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159, 161, 162, 163, 164, 165, 166, 167, 168, 169, 171, 172, 173, 174];
  var emojiGlyphs = [1, 2.5, 4, 5, 6.5, 7.5, 9, 10, 11.5, 12.5, 14, 15, 16.5, 17.5, 19, 20, 20.5, 21, 21.5, 22, 22.5, 23, 23.5, 24, 24.5, 25.5, 26.5, 27.5, 28.5, 29.5, 30.5, 31.5, 32.5, 33.5, 34.5, 35.5, 36.5, 37.5, 38.5, 39.5, 40.5, 41.5, 42.5, 43.5, 44.5, 45.5, 46.5, 47.5, 48.5, 49.5, 50.5, 51.5, 52.5, 53.5, 54.5, 55.5, 56.5, 57.5, 58.5, 59.5, 60.5, 61.5, 62.5, 63.5, 64.5, 65.5, 66, 66.5, 67.5, 68.5, 69.5, 70.5, 71.5, 72.5, 73.5, 74.5, 75.5, 76.5, 77.5, 78.5, 79.5, 80.5, 81.5, 82.5, 83.5, 84.5, 85.5, 86.5, 87.5, 88.5, 89.5, 90.5, 91.5, 92.5, 93.5, 94.5, 95.5, 96.5, 97.5, 98.5, 99.5, 100.5, 101.5, 102.5, 103.5, 104.5, 105.5, 106.5, 107.5, 108.5, 109.5, 110.5, 111.5, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157, 158];
  var emojiRun = /(\p{Extended_Pictographic}(?:\uFE0F|\u200D\p{Extended_Pictographic}|[\u{1F3FB}-\u{1F3FF}])*|[\u{1F1E6}-\u{1F1FF}]{2})/u;
  var hanAdvances = [0.994, 1.988, 2.982, 3.977, 4.971, 5.965, 6.959, 7.953, 8.947, 9.942, 10.936, 11.918, 12.899, 13.891, 14.883, 15.875, 16.851, 17.842, 18.834, 19.154, 20.053, 20.945, 21.898, 22.85, 23.802, 24.754, 25.706, 26.658, 27.583, 28.506, 29.427, 30.346, 31.263, 32.211, 33.158, 34.105, 35.018, 35.964, 36.911, 37.82, 38.765, 39.711, 40.656, 41.56, 42.505, 43.449, 44.35, 45.293, 46.237, 47.18, 48.124, 49.068, 50.011, 50.955, 51.898, 52.842, 53.786, 54.729, 55.673, 56.617, 57.56, 58.504, 59.447, 60.391, 61.335, 62.278, 63.222, 64.165, 65.109, 66.053, 66.996, 67.94, 68.883, 69.827, 70.771, 71.714, 72.658, 73.602, 74.545, 75.489, 76.432, 77.376, 78.32, 79.263, 80.207, 81.15, 82.094, 83.038, 83.981, 84.925, 85.868, 86.812, 87.756, 88.699, 89.643, 90.586, 91.53, 92.474, 93.417, 94.361, 95.305, 96.248, 97.192, 98.135, 99.079, 100.023, 100.966, 101.91, 102.853, 103.797, 104.741, 105.684, 106.628, 107.571, 108.515, 109.459, 110.402, 111.346, 112.289, 113.233, 114.177, 115.12, 116.064, 117.008, 117.951, 118.895, 119.838, 120.782, 121.726, 122.669, 123.613, 124.556, 125.5, 126.444, 127.387, 128.331, 129.274, 130.218, 131.162, 132.105, 133.049, 133.992, 134.936, 135.88, 136.823, 137.767, 138.711, 139.654, 140.598, 141.541, 142.485, 143.429, 144.372, 145.316, 146.259, 147.203, 148.147, 149.09, 150.034, 150.977];
  var hanRun = /(\p{Script=Han}+)/u;
  var hanAdvance = (size) => {
    const index = Math.min(hanAdvances.length, Math.max(1, size)) - 1;
    const low = Math.floor(index);
    const high = Math.min(hanAdvances.length - 1, low + 1);
    const value = hanAdvances[low] + (hanAdvances[high] - hanAdvances[low]) * (index - low);
    return size > hanAdvances.length ? value * size / hanAdvances.length : value;
  };
  function fillText(element, text, adjust) {
    const emoji = adjust?.emoji && emojiRun.test(text) ? adjust.emoji : null;
    const han = adjust?.han && hanRun.test(text) ? adjust.han : null;
    if (!emoji && !han) {
      element.textContent = text;
      return;
    }
    const doc = element.ownerDocument;
    const pattern = new RegExp(`${emoji ? emojiRun.source : "(?!)"}|${han ? hanRun.source : "(?!)"}`, "u");
    element.replaceChildren(...text.split(pattern).filter((part) => part !== void 0 && part !== "").map((part) => {
      const span = doc.createElement("span");
      if (emoji && emojiRun.test(part)) Object.assign(span.style, { fontSize: `${emoji.fontSize}px`, lineHeight: "0", padding: `0 ${emoji.padding}px`, position: "relative", top: `${emoji.drop}px` });
      else if (han && hanRun.test(part)) span.style.letterSpacing = `${han.letterSpacing}px`;
      else return doc.createTextNode(part);
      span.textContent = part;
      return span;
    }));
  }
  function createTextMeasurer(doc) {
    const host = doc.createElement("div");
    Object.assign(host.style, { position: "absolute", left: "-100000px", top: "0", visibility: "hidden", contain: "layout style" });
    const probe = doc.createElement("div");
    probe.style.whiteSpace = "pre-wrap";
    probe.style.overflowWrap = "break-word";
    host.appendChild(probe);
    doc.body.appendChild(host);
    const cache = /* @__PURE__ */ new Map();
    const apply = (style) => {
      probe.style.fontFamily = style.family;
      probe.style.fontSize = `${style.size}px`;
      probe.style.fontWeight = String(style.weight);
      probe.style.lineHeight = `${style.leading}px`;
      probe.style.fontVariantNumeric = style.design === "serif" && !style.custom ? "lining-nums" : "";
    };
    const measure = (text, style, width) => {
      const key = `${style.key}|${width}|${text}`;
      if (cache.has(key)) return cache.get(key);
      apply(style);
      probe.style.width = width === null ? "max-content" : `${width}px`;
      fillText(probe, text, textAdjustments(style));
      const range = doc.createRange();
      range.selectNodeContents(probe);
      const rects = [...range.getClientRects()].filter((rect) => rect.width > 0 || rect.height > 0);
      const measuredWidth = rects.length ? Math.max(...rects.map((rect) => rect.right)) - Math.min(...rects.map((rect) => rect.left)) : 0;
      const lines = Math.max(1, Math.round(probe.getBoundingClientRect().height / style.leading));
      const result = { width: measuredWidth, lines };
      cache.set(key, result);
      return result;
    };
    const emojiStyles = /* @__PURE__ */ new Map();
    function emojiSize(style) {
      if (emojiStyles.has(style.key)) return emojiStyles.get(style.key);
      apply(style);
      probe.style.width = "max-content";
      probe.textContent = "🐠";
      const measured = probe.getBoundingClientRect().width;
      const index = Math.round(style.size) - 1;
      const advance = emojiAdvances[index] ?? style.size * 1.09;
      const glyph = emojiGlyphs[index] ?? style.size;
      const result = measured > 0 && Math.abs(measured - advance) > 0.5 ? { fontSize: style.size * glyph / measured, padding: Math.max(0, (advance - glyph) / 2), drop: Math.max(0, (glyph - style.size) / 2) } : null;
      emojiStyles.set(style.key, result);
      return result;
    }
    const hanStyles = /* @__PURE__ */ new Map();
    function hanSpacing(style) {
      if (hanStyles.has(style.key)) return hanStyles.get(style.key);
      apply(style);
      probe.style.width = "max-content";
      probe.textContent = "今".repeat(10);
      const measured = probe.getBoundingClientRect().width / 10;
      const delta = hanAdvance(style.size) - measured;
      const result = measured > 0 && Math.abs(delta) > 0.02 ? { letterSpacing: delta } : null;
      hanStyles.set(style.key, result);
      return result;
    }
    const textAdjustments = (style) => ({ emoji: emojiSize(style), han: hanSpacing(style) });
    const baselines = /* @__PURE__ */ new Map();
    function baseline(style) {
      if (baselines.has(style.key)) return baselines.get(style.key);
      apply(style);
      probe.style.width = "max-content";
      const marker = doc.createElement("span");
      Object.assign(marker.style, { display: "inline-block", width: "0", height: "0", verticalAlign: "baseline" });
      probe.replaceChildren(doc.createTextNode("H"), marker);
      const value = marker.getBoundingClientRect().top - probe.getBoundingClientRect().top;
      baselines.set(style.key, value);
      return value;
    }
    return {
      measure,
      baseline,
      emojiSize,
      textAdjustments,
      ellipsisWidth: (style) => measure("…", style, null).width,
      dispose() {
        host.remove();
      }
    };
  }

  // ../Web/preview-engine/src/render/renderer.js
  var maskCounter = 0;
  function closedPath(d) {
    if (/z/i.test(d)) return true;
    const start = /^\s*M\s*(-?[\d.]+)[\s,]*(-?[\d.]+)/.exec(d);
    const lastCommand = /([A-Za-z])[^A-Za-z]*$/.exec(d);
    if (!start || !lastCommand || lastCommand[1] !== lastCommand[1].toUpperCase()) return false;
    const numbers = d.match(/-?\d*\.?\d+/g) ?? [];
    return numbers.length >= 2 && Number(numbers.at(-2)) === Number(start[1]) && Number(numbers.at(-1)) === Number(start[2]);
  }
  function lucideIconFor(systemName) {
    const variants = /* @__PURE__ */ new Set();
    let name = systemName;
    variants.add(name);
    const stripped = name.replace(/\.(fill|circle|square|rectangle|slash|badge|inverse)(?=\.|$)/g, "");
    variants.add(stripped);
    const parts = stripped.split(".");
    for (let length = parts.length - 1; length > 0; length -= 1) variants.add(parts.slice(0, length).join("."));
    for (const variant of variants) if (sfSymbolToLucide[variant]) return lucideIcons[sfSymbolToLucide[variant]];
    return null;
  }
  var BottomOverlayNode = class extends Node {
    constructor(base, overlay) {
      super();
      this.base = base;
      this.overlay = overlay;
      this.children = [base, overlay];
    }
    size(pw, ph) {
      return this.base.size(pw, ph);
    }
    place(x, y, width, height) {
      super.place(x, y, width, height);
      this.base.place(0, 0, width, height);
      const [w, h] = this.overlay.size(width, height);
      this.overlay.place((width - w) / 2, height - h, w, h);
    }
  };
  var naturalLineRatio = 1.1934;
  var macLineHeights = [2, 3, 4, 5, 7, 8, 9, 10, 11, 13, 14, 15, 16, 17, 19, 19, 20, 21, 23, 24, 25, 26, 27, 28, 29, 30, 32, 33, 34, 35, 37, 38, 39, 40, 41, 43, 44, 45, 46, 47, 49, 50, 51, 52, 53, 54, 55, 56, 57, 59, 60, 61, 62, 63, 65, 66, 67, 68, 69, 71, 72, 73, 74, 76, 77, 78, 79, 80, 82, 83, 84, 85, 86, 88, 89, 89, 90, 91, 93, 94, 95, 96, 98, 99, 100, 101, 102, 104, 105, 106, 107, 108, 110, 111, 112, 113, 114, 116, 117, 118, 119, 121, 122, 123, 124, 124, 126, 127, 128, 129, 130, 132, 133, 134, 135, 136, 138, 139, 140, 141, 143, 144, 145, 146, 147, 149, 150, 151, 152, 153, 155, 156, 157, 158, 159, 160, 161, 162, 163, 165, 166, 167, 168, 169, 171, 172, 173, 174, 175, 177, 178, 179, 180, 181, 183, 184, 185, 186, 188, 189];
  function lineHeight(size) {
    if (platform() === "macos") {
      const whole = Math.ceil(size);
      if (whole <= 0) return 0;
      return macLineHeights[whole - 1] ?? Math.ceil(size * naturalLineRatio);
    }
    return Math.ceil(size * naturalLineRatio * 2) / 2;
  }
  var macBaselines = [0.75, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155];
  function nativeBaseline(size) {
    if (platform() === "macos") return macBaselines[Math.ceil(size) - 1] ?? size * 0.9521;
    return size * 0.9521;
  }
  var numericVariant = (style) => style.design === "serif" && !style.custom ? "lining-nums" : "";
  function textStyleFor(font) {
    const natural = font.natural ?? lineHeight(font.size);
    const leading = platform() === "macos" ? Math.max(natural, font.lineHeight ?? natural) : font.lineHeight ?? font.size * naturalLineRatio;
    const family = fontFamily(font);
    return { ...font, natural, leading, family, custom: Boolean(font.family), hyphenate: Boolean(font.textStyle), key: `${family}|${font.size}|${font.weight}|${leading}` };
  }
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
  var isElement = (value) => value !== null && typeof value === "object" && "tag" in value && "children" in value && "props" in value;
  function childrenAsElements(element) {
    const result = [];
    const visit = (items) => {
      for (const item of items) {
        if (isElement(item)) result.push(item);
        else if (Array.isArray(item)) visit(item);
      }
    };
    visit(element.children ?? []);
    return result;
  }
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
    if (element.tag === "image") {
      const url = reader.string("url", "src");
      const drawable = url ? drawableURL(url) : null;
      if (drawable) urls.add(drawable);
    }
    childrenAsElements(element).forEach((child) => collectImageURLs(child, urls, drawableURL));
  }
  async function naturalSizes(urls, doc) {
    const sizes = /* @__PURE__ */ new Map();
    await Promise.all([...urls].map(async (url) => {
      const image = doc.createElement("img");
      image.src = url;
      try {
        await image.decode();
        sizes.set(url, [image.naturalWidth, image.naturalHeight]);
      } catch {
      }
    }));
    return sizes;
  }
  async function renderWidget(treeJSON, {
    family = "medium",
    profile = "iphone-393",
    appearance = "light",
    renderingMode = "fullColor",
    lockScreen = true,
    resources = {},
    document: doc = globalThis.document,
    now = null,
    animations = "live",
    animationElapsed = null,
    reduceTransparency = false,
    reduceMotion = false,
    // Native hosts (Android) supply these; the web hosts use the defaults.
    size: explicitSize = null,
    textMeasurer = null,
    resolveImageURL = null,
    gifPreparer = null
  } = {}) {
    const fixedNow = typeof now === "number" && Number.isFinite(now) ? now : null;
    if (reduceMotion) animations = "firstFrame";
    const size = explicitSize ?? widgetSize(profile, family);
    const drawableURL = resolveImageURL ?? ((url) => /^data:image\/(png|jpeg);base64,/.test(url) ? url : null);
    const diagnostics = [];
    const reported = /* @__PURE__ */ new Set();
    const report = (severity, code, message) => {
      const key = `${code}:${message}`;
      if (!reported.has(key)) {
        reported.add(key);
        diagnostics.push({ severity, code, message });
      }
    };
    const color = (value) => parseColor(value, appearance);
    let tint = null;
    const primary = () => tint ?? color("primary");
    const root = decodeTree(treeJSON);
    const urls = /* @__PURE__ */ new Set(), gifUses = /* @__PURE__ */ new Map(), preparedGifs = /* @__PURE__ */ new Map();
    for (const [path, url] of Object.entries(resources)) if (path.startsWith("image/") && !/\.gif$/i.test(path)) urls.add(url);
    collectImageURLs(root, urls, drawableURL);
    const collectGifs = (element) => {
      if (!isElement(element)) return;
      const reader = propReader(element.props);
      const found = element.tag === "gif" ? packageGif(reader.string("file") ?? "") : element.tag === "image" ? packageImage(reader.string("name", "id") ?? "") : null;
      const url = typeof found === "string" ? found : found && /\.gif$/i.test(found.path) ? found.url : null;
      if (url) {
        const use = gifUses.get(url) ?? { image: false };
        use.image ||= element.tag === "image";
        gifUses.set(url, use);
      }
      childrenAsElements(element).forEach(collectGifs);
    };
    collectGifs(root);
    for (const [url, use] of gifUses) {
      try {
        const value = await (gifPreparer ?? prepareGif)(url, { document: doc, firstFrame: reduceMotion || animations === "firstFrame" || deviceProfiles[profile]?.platform === "macos", needImage: use.image });
        preparedGifs.set(url, value);
        if (value.firstFrame) urls.add(value.firstFrame);
        if (value.info.frameLimit || value.memoryFallback) report("warning", "gif.static_fallback", "GIF uses its first frame because the preview animation budget was exceeded");
      } catch {
        preparedGifs.set(url, null);
        report("warning", "gif.unavailable", "GIF could not be decoded within preview input and canvas limits");
      }
    }
    const imageSizes = await naturalSizes(urls, doc);
    const measurer = textMeasurer ?? createTextMeasurer(doc);
    const leaf = (node, draw2) => Object.assign(node, { draw: draw2 });
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
    function text(value, font, inputPaint, alignment = "left") {
      const style = textStyleFor(font);
      const paint = inputPaint ?? { color: primary() };
      return leaf(new TextNode(value, style, measurer), (node, element) => {
        Object.assign(element.style, {
          fontFamily: style.family,
          fontSize: `${style.size}px`,
          fontWeight: String(style.weight),
          lineHeight: `${style.leading}px`,
          whiteSpace: "pre-wrap",
          overflowWrap: "break-word",
          textAlign: alignment,
          fontVariantNumeric: numericVariant(style)
        });
        const content = element.ownerDocument.createElement("div");
        const truncated = node.lines?.text ?? (node.lines && node.lines.lines < node.lines.total ? node.ellipsize(node.text, node.frame.width) : null);
        fillText(content, truncated ?? node.displayText(node.frame.width), measurer.textAdjustments(style));
        const trim = style.design === "default" && !style.custom ? measurer.baseline(style) - nativeBaseline(style.size) : (style.leading - style.natural) / 2;
        Object.assign(content.style, { marginTop: `${-trim}px`, width: `${node.frame.width + 0.5}px` });
        if (node.lines?.clip) {
          content.style.whiteSpace = "pre";
          element.style.overflow = "hidden";
        }
        if (alignment !== "left") content.style.width = `${node.frame.width}px`;
        if (truncated !== null) Object.assign(content.style, { whiteSpace: "pre", overflow: "hidden" });
        applyTextPaint(content, paint, node.frame.width, node.frame.height);
        element.appendChild(content);
      });
    }
    function applyTextPaint(element, paint, width, height) {
      if (paint?.gradient) {
        Object.assign(element.style, { color: "transparent", backgroundImage: gradientCSS(paint.gradient, width, height) });
        element.style.webkitBackgroundClip = "text";
        element.style.backgroundClip = "text";
      } else element.style.color = cssColor(paint?.color ?? primary());
    }
    const paintOf = (reader, field) => reader.string(field) !== null ? parsePaint(reader.string(field), appearance) : null;
    function shape(kind, paint, { strokeWidth = null, trim = null, cornerRadius = 0 } = {}) {
      return leaf(new FlexibleNode(), (node, element) => {
        const { width, height } = node.frame;
        let x = 0;
        let y = 0;
        let w = width;
        let h = height;
        let r = 0;
        if (kind === "circle") {
          const d = Math.min(width, height);
          x = (width - d) / 2;
          y = (height - d) / 2;
          w = d;
          h = d;
        }
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
        svg.setAttribute("width", String(width));
        svg.setAttribute("height", String(height));
        Object.assign(svg.style, { overflow: "visible", position: "absolute", left: "0", top: "0" });
        const outline = element.ownerDocument.createElementNS(svgNS, elliptical ? "ellipse" : "rect");
        const attributes = elliptical ? { cx: x + w / 2, cy: y + h / 2, rx: w / 2, ry: h / 2 } : { x, y, width: w, height: h, rx: r, ry: r };
        for (const [key, value] of Object.entries(attributes)) outline.setAttribute(key, String(value));
        let colorValue = paint.color;
        if (paint.gradient) {
          report("info", "prop.approximated", "Gradient strokes use the first gradient color");
          colorValue = paint.gradient.colors[0] ?? primary();
        }
        if (strokeWidth !== null) {
          outline.setAttribute("fill", "none");
          outline.setAttribute("stroke", cssColor(colorValue));
          outline.setAttribute("stroke-width", String(strokeWidth));
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
        if (parts.length === 1) {
          const from = swiftDouble(parts[0]);
          if (from !== null && from >= 0 && from <= 1) trim = [from, 1];
        } else if (parts.length === 2 && swiftDouble(parts[0]) !== null && swiftDouble(parts[1]) !== null) trim = [swiftDouble(parts[0]), swiftDouble(parts[1])];
      }
      return { strokeWidth, trim };
    }
    function ring(thickness, tint2, track, progress, fixedSize = null) {
      const node = fixedSize ? new FixedNode(fixedSize, fixedSize) : new FlexibleNode();
      return leaf(node, (target, element) => {
        const { width, height } = target.frame;
        const svgNS = "http://www.w3.org/2000/svg";
        const svg = element.ownerDocument.createElementNS(svgNS, "svg");
        svg.setAttribute("width", String(width));
        svg.setAttribute("height", String(height));
        Object.assign(svg.style, { position: "absolute", left: "0", top: "0", overflow: "visible" });
        const circle = (stroke, dash) => {
          const item = element.ownerDocument.createElementNS(svgNS, "circle");
          for (const [key, value] of Object.entries({ cx: width / 2, cy: height / 2, r: Math.min(width, height) / 2, fill: "none", stroke: cssColor(stroke), "stroke-width": thickness })) item.setAttribute(key, String(value));
          if (dash !== void 0) {
            item.setAttribute("pathLength", "1");
            item.setAttribute("stroke-dasharray", `${dash} 2`);
            item.setAttribute("stroke-linecap", "round");
            item.setAttribute("transform", `rotate(-90 ${width / 2} ${height / 2})`);
          }
          return item;
        };
        svg.appendChild(circle(track));
        if (progress > 0) svg.appendChild(circle(tint2, progress));
        element.appendChild(svg);
      });
    }
    function packageImage(name) {
      const trimmed = name.trim();
      if (trimmed === "" || trimmed.includes("..")) return null;
      const base = `image/${trimmed}`;
      const candidates = /\.[A-Za-z0-9]+$/.test(trimmed) ? [base] : ["png", "jpg", "jpeg", "webp", "heic"].map((ext) => `${base}.${ext}`);
      for (const candidate of candidates) if (resources[candidate]) return { path: candidate, url: resources[candidate] };
      return null;
    }
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
        image.src = url;
        image.alt = "";
        Object.assign(image.style, { position: "absolute", left: "0", top: "0", width: "100%", height: "100%", objectFit: fit });
        element.appendChild(image);
      };
    }
    function glyph(systemName, font, inputPaint) {
      const paint = inputPaint ?? { color: primary() };
      const style = textStyleFor(font);
      const containerMatch = /^(.+)\.(circle|square)\.fill$/.exec(systemName);
      const container = containerMatch?.[2] ?? null;
      const icon = container ? lucideIconFor(containerMatch[1]) ?? [] : lucideIconFor(systemName);
      if (icon) report("info", "icon.approximated", `SF Symbol "${systemName}" is drawn with an open-source look-alike icon`);
      else report("warning", "icon.unmapped", `SF Symbol "${systemName}" has no web icon yet; a placeholder is shown`);
      const ratio = symbolMetrics[systemName] ?? symbolMetrics[systemName.replace(/\.fill(?=\.|$)/g, "")];
      const half = (value) => Math.round(value * 2) / 2;
      const box = ratio ? [half(style.size * ratio[0]), half(style.size * ratio[1])] : [Math.ceil(style.size * 1.2 * 2) / 2, style.natural];
      const fixed = new FixedNode(box[0], box[1]);
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
        for (const [key, value] of Object.entries({
          width: side,
          height: side,
          viewBox: "0 0 24 24",
          fill: "none",
          stroke: colorValue,
          "stroke-width": String(Math.max(1.5, Math.min(3, 1.4 + (style.weight - 100) / 400))),
          "stroke-linecap": "round",
          "stroke-linejoin": "round"
        })) svg.setAttribute(key, String(value));
        Object.assign(svg.style, { position: "absolute", left: `${(width - side) / 2}px`, top: `${(height - side) / 2}px` });
        const shape2 = symbolShapes[systemName];
        if (shape2) {
          svg.setAttribute("fill", "currentColor");
          svg.setAttribute("stroke", "none");
          Object.assign(svg.style, { color: colorValue, overflow: "visible" });
          svg.innerHTML = shape2(`sw-cut-${++maskCounter}`);
          element.appendChild(svg);
          return;
        }
        if (container) {
          const id = `sw-cut-${++maskCounter}`;
          const strokeWidth = Number(svg.getAttribute("stroke-width"));
          svg.innerHTML = `<defs><mask id="${id}" maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24"><rect width="24" height="24" fill="white"/><g transform="translate(12 12) scale(0.58) translate(-12 -12)" stroke="black" fill="none" stroke-width="${strokeWidth * 1.45}"></g></mask></defs>` + (container === "circle" ? `<circle cx="12" cy="12" r="11" stroke="none" fill="${colorValue}" mask="url(#${id})"/>` : `<rect x="1.5" y="1.5" width="21" height="21" rx="5" stroke="none" fill="${colorValue}" mask="url(#${id})"/>`);
          const cut = svg.querySelector("g");
          for (const [tag, attributes] of icon) {
            const item = element.ownerDocument.createElementNS(svgNS, tag);
            for (const [key, value] of Object.entries(attributes)) item.setAttribute(key, String(value));
            cut.appendChild(item);
          }
          element.appendChild(svg);
          return;
        }
        const turn = { airplane: 45, "airplane.departure": 0, "quote.opening": 180 }[systemName];
        if (turn) svg.style.transform = `rotate(${turn}deg)`;
        const filled = /\.fill(\.|$)/.test(systemName);
        for (const [tag, attributes] of icon) {
          const item = element.ownerDocument.createElementNS(svgNS, tag);
          for (const [key, value] of Object.entries(attributes)) item.setAttribute(key, String(value));
          const closed = tag === "circle" || tag === "rect" || tag === "ellipse" || tag === "polygon" || tag === "path" && closedPath(attributes.d ?? "");
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
          const prepared = /\.gif$/i.test(found.path) ? preparedGifs.get(found.url) : void 0;
          if (/\.gif$/i.test(found.path) && !prepared?.firstFrame) return text("GIF unavailable", defaultFont(), null);
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
    function defaultSpacing(axis) {
      return (previous, next) => {
        if (previous.isSpacer || next.isSpacer) return 0;
        if (axis === "h") return 8;
        const above = previous.edge("bottom");
        const below = next.edge("top");
        const half = (value) => Math.round(value * 2) / 2;
        if (above?.symbol || below?.symbol) {
          if (above && below) return 0;
          if (above) return half(0.135 * above.size + 1);
          return Math.ceil(0.1354 * below.size * 2) / 2;
        }
        if (platform() === "macos") {
          const step = (size2) => Math.ceil(0.118 * size2 * 2) / 2;
          if (above && below) return below.gap ?? 0;
          if (above) return half(0.4729 * above.size + step(above.size));
          if (below) return half(0.2109 * below.size + step(below.size));
          return 8;
        }
        if (above && below) return below.textStyle ? Math.max(0, Math.ceil((below.lineHeight - below.size * naturalLineRatio) * 2) / 2) : 0;
        if (above) return half(0.6094 * above.size);
        if (below) return Math.ceil(0.3625 * below.size * 2) / 2;
        return 8;
      };
    }
    function stack(axis, children, reader) {
      const alignment = reader.string("alignment");
      const cross = axis === "v" ? { leading: "start", trailing: "end" }[alignment] ?? "center" : { top: "start", bottom: "end", firstTextBaseline: "start", lastTextBaseline: "end" }[alignment] ?? "center";
      const explicit = reader.double("spacing");
      return new StackNode(axis, children, { alignment: cross, spacing: explicit !== null ? () => explicit : defaultSpacing(axis) });
    }
    function buildChildren(element, axis) {
      const result = [];
      for (const child of childrenAsElements(element)) {
        if (child.tag === "Fragment") result.push(...buildChildren(child, axis));
        else result.push(build(child, axis));
      }
      return result;
    }
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
      const parsedAnimation = parseAnimation(reader.string("animation"));
      const animation = platform() === "macos" ? clockPeriods[parsedAnimation?.type] ? parsedAnimation : null : parsedAnimation;
      if (platform() === "macos" && reader.string("animation") !== null) report("info", "animation.macos", "Mac shows static clock poses; other animations remain at rest");
      if (animation?.type === "error") return text("animation json error", defaultFont(), null);
      if (animation) {
        if (Object.keys(decoration).length) node = new DecorationNode(node, { ...decoration, keepsEdges: !padding && frame.mode === "none" });
        node = new DecorationNode(node, { animation, keepsEdges: true });
        for (const key of Object.keys(decoration)) delete decoration[key];
      }
      const transforms = [];
      const rotation = reader.double("rotation");
      if (rotation !== null) transforms.push(`rotate(${rotation}deg)`);
      const rotation3d = reader.string("rotation3d");
      if (rotation3d !== null && !reduceMotion) {
        const rotation2 = parseRotation3D(rotation3d);
        if (rotation2) transforms.push(`perspective(400px) rotate3d(${rotation2.x}, ${rotation2.y}, ${rotation2.z}, ${rotation2.degree}deg)`);
      }
      if (transforms.length) decoration.transform = transforms.join(" ");
      const shadow = reader.string("shadow");
      if (shadow !== null) {
        const parts = shadow.split(",");
        let shadowColor = null;
        let radius = 3;
        let x = 0;
        let y = 3;
        if (parts.length === 1) shadowColor = color(shadow);
        else if (parts.length === 4) {
          shadowColor = color(parts[0]);
          radius = swiftDouble(parts[1]) ?? radius;
          x = swiftDouble(parts[2]) ?? x;
          y = swiftDouble(parts[3]) ?? y;
        }
        if (shadowColor) decoration.filter = `drop-shadow(${x}px ${y}px ${radius / 2}px ${cssColor(shadowColor)})`;
      }
      if (reader.bool("widgetAccentable") === true) decoration.accentable = true;
      if (Object.keys(decoration).length) {
        decoration.keepsEdges = !padding && frame.mode === "none";
        node = new DecorationNode(node, decoration);
      }
      return node;
    }
    function parseAnimation(value) {
      if (value === null) return null;
      if (value.startsWith("animation:")) {
        let json;
        try {
          json = JSON.parse(value.slice("animation:".length), (_, value2) => {
            if (typeof value2 === "number" && !Number.isFinite(value2)) throw new Error("Invalid animation number");
            return value2;
          });
        } catch {
          return { type: "error" };
        }
        const type = typeof json?.type === "string" ? json.type : "";
        if (type === "clock") {
          return { type, timezone: typeof json.timezone === "string" ? json.timezone : "current", anchor: typeof json.anchor === "string" ? json.anchor : "center", interval: typeof json.interval === "number" ? clockPeriod(json.interval) : 10 };
        }
        if (type === "swing") return { type, duration: swingDuration(json.duration), direction: json.direction === "horizontal" ? "horizontal" : json.direction === void 0 ? "horizontal" : "vertical", distance: swingDistance(json.distance) };
        return clockPeriods[type] ? { type, timezone: typeof json.timezone === "string" ? json.timezone : "current", anchor: typeof json.anchor === "string" ? json.anchor : "center" } : null;
      }
      const parts = value.split(",").filter((part) => part !== "");
      if (parts.length === 1) return clockPeriods[value] || value === "swing" ? value === "swing" ? { type: "swing", duration: 1, direction: "horizontal", distance: 10 } : { type: value, timezone: "current", anchor: "center" } : null;
      if (parts.length === 2 && parts[0].trim() === "clockCustom" && swiftDouble(parts[1].trim()) !== null) return { type: "clock", timezone: "current", anchor: "center", interval: clockPeriod(swiftDouble(parts[1].trim())) };
      return null;
    }
    function build(element, axis = "z", { isRoot = false } = {}) {
      const reader = propReader(element.props);
      checkProps(element, reader);
      const tag = element.tag;
      let content;
      switch (tag) {
        case "vstack":
          content = stack("v", buildChildren(element, "v"), reader);
          break;
        case "hstack":
          content = stack("h", buildChildren(element, "h"), reader);
          break;
        case "zstack":
          content = new ZStackNode(buildChildren(element, "z"));
          break;
        case "text":
        case "date": {
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
        case "capsule":
        case "ellipse":
        case "circle":
          content = shape(tag, paintOf(reader, "color") ?? { color: primary() }, shapeOptions(reader));
          break;
        case "roundedrect":
          content = shape("rounded", { color: color(reader.string("color") ?? "#e2e8f0") ?? color("gray") }, { cornerRadius: reader.double("radius") ?? 12 });
          break;
        case "divider":
        case "line": {
          const thickness = reader.double("thickness") ?? (tag === "divider" ? 1 : 2);
          const fill = { color: color(reader.string("color") ?? "secondary") ?? color("secondary") };
          const vertical = reader.string("axis") === "vertical";
          const length = reader.double("length") ?? 48;
          const frame = tag === "line" ? { mode: "size", width: vertical ? thickness : length, height: vertical ? length : thickness } : vertical ? { mode: "width", width: thickness } : { mode: "height", height: thickness };
          content = new FrameNode(shape("rect", fill), { ...frame, alignment: alignments.center });
          break;
        }
        case "icon": {
          const base = reader.double("size") !== null ? { ...defaultFont(), natural: void 0, gap: void 0, lineHeight: null, size: reader.double("size") } : defaultFont();
          content = glyph(reader.string("systemName") ?? "questionmark.circle", elementFont(reader, base), paintOf(reader, "color"));
          break;
        }
        case "image":
          content = imageNode(reader);
          break;
        case "gif": {
          const url = packageGif(reader.string("file") ?? "");
          if (url && preparedGifs.get(url)?.url) {
            report("info", "tag.approximated", "<gif> uses bounded browser playback or a static frame; native WidgetKit timing differs");
            content = leaf(new FlexibleNode(), drawPicture(preparedGifs.get(url).url, "contain"));
          } else content = text("GIF unavailable", defaultFont(), null);
          break;
        }
        case "label": {
          const font = elementFont(reader);
          const paint = paintOf(reader, "color");
          content = new StackNode("h", [glyph(reader.string("systemName") ?? "circle.fill", font, paint), text(reader.string("title") ?? textFromChildren(element), font, paint)], { alignment: "center", spacing: () => 8 });
          break;
        }
        case "badge":
        case "chip": {
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
        case "progress":
          content = progressNode(reader);
          break;
        case "ring": {
          const value = Math.min(Math.max(reader.double("value") ?? 0, 0), 1);
          content = ring(reader.double("thickness") ?? 8, color(reader.string("color") ?? "#3b82f6") ?? color("blue"), color(reader.string("trackColor") ?? "#e2e8f0") ?? [142, 142, 147, 0.2], value);
          break;
        }
        case "link":
        case "button":
        case "toggle": {
          const outerTint = tint;
          const macButton = tag === "button" && platform() === "macos";
          if (tag === "button" && !macButton) tint = color("blue");
          const macToggle = tag === "toggle" && platform() === "macos";
          const labelColor = appearance === "dark" ? [255, 255, 255, 0.85] : [0, 0, 0, 0.85];
          const children = macToggle ? childrenAsElements(element).map((child, index) => {
            tint = index === 0 ? labelColor : color("secondary");
            return build(child, "v");
          }) : buildChildren(element, "v");
          tint = outerTint;
          if (macToggle) {
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
            content = new StackNode(tag === "button" ? "h" : "v", children, { alignment: "center", spacing: defaultSpacing(tag === "button" ? "h" : "v") });
            if (macButton) {
              const bezel = appearance === "dark" ? [255, 255, 255, 0.0745] : [0, 0, 0, 0.0745];
              content = new DecorationNode(new PaddingNode(content, [4, 12, 4, 12]), { background: { color: bezel }, cornerRadius: 5 });
            }
          }
          break;
        }
        case "hgrid":
        case "vgrid":
          content = gridNode(element, reader, tag === "vgrid" ? "v" : "h");
          break;
        case "gauge":
          content = gaugeNode(reader);
          break;
        case "chart":
          content = chartNode(reader);
          break;
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
    function interactionFor(tag, reader) {
      const text2 = (name) => reader.string(name);
      if (tag === "link") return text2("url") !== null ? { type: "link", url: text2("url") } : null;
      if (tag === "button") return { type: "button", action: text2("action"), actionID: text2("actionID"), handler: text2("onClick") };
      if (tag === "toggle") return { type: "toggle", on: reader.bool("on") ?? false, actionID: text2("actionID"), stateKey: text2("stateKey"), handler: text2("onClick") };
      return text2("linkurl") !== null ? { type: "link", url: text2("linkurl") } : null;
    }
    function dateDescription(reader) {
      const { style, real, date } = resolveDate(reader);
      return { style, target: date.getTime(), live: Math.abs(date.getTime() - real.getTime()) < 1e3 };
    }
    function progressNode(reader) {
      const value = Math.max(reader.double("value") ?? 0, 0);
      const total = Math.max(reader.double("total") ?? 1, 1e-6);
      const progress = Math.min(value / total, 1);
      const label = reader.string("label") ?? "";
      const tint2 = color(reader.string("color") ?? "#3b82f6") ?? color("blue");
      const track = (reader.string("trackColor") !== null ? color(reader.string("trackColor")) : null) ?? [255, 255, 255, 0.15];
      const thickness = reader.double("thickness") ?? 6;
      if ((reader.string("style") ?? "linear") === "circular") {
        const side = reader.double("frame") ?? 32;
        const children2 = [ring(thickness, tint2, track, progress, side)];
        if (label) children2.push(text(label, styleFont("caption2"), null));
        return new FrameNode(new ZStackNode(children2), { mode: "size", width: side, height: side, alignment: alignments.center });
      }
      const bar = leaf(new FlexibleNode(), (node, element) => {
        Object.assign(element.style, { borderRadius: `${thickness / 2}px`, backgroundColor: cssColor(track), overflow: "hidden" });
        const fill = element.ownerDocument.createElement("div");
        Object.assign(fill.style, { position: "absolute", left: "0", top: "0", height: "100%", width: `${node.frame.width * progress}px`, borderRadius: `${thickness / 2}px`, backgroundColor: cssColor(tint2) });
        element.appendChild(fill);
      });
      const barFrame = new FrameNode(bar, { mode: "height", height: thickness, alignment: alignments.center });
      const children = label ? [text(label, styleFont("caption2"), null), barFrame] : [barFrame];
      return new StackNode("v", children, { alignment: "start", spacing: () => label ? 4 : 0 });
    }
    const dateStyle = (reader) => ({ time: "time", date: "date", relative: "relative", offset: "offset", timer: "timer" })[reader.string("style") ?? "timer"] ?? "time";
    function resolveDate(reader) {
      const style = dateStyle(reader);
      const real = /* @__PURE__ */ new Date();
      const now2 = fixedNow !== null && (style === "time" || style === "date") ? new Date(fixedNow) : real;
      let date = now2;
      const name = reader.string("date");
      if (name !== null) {
        if (name === "tomorrow") date = new Date(now2.getTime() + 864e5);
        else if (name === "yesterday") date = new Date(now2.getTime() - 864e5);
        else if (name === "start of today") date = new Date(now2.getFullYear(), now2.getMonth(), now2.getDate());
        else if (name.startsWith("+") || name.startsWith("-")) {
          let step = 36e5 * (name.startsWith("+") ? 1 : -1);
          if (name.endsWith("d")) step *= 24;
          const middle = name.length >= 3 ? Number.parseInt(name.slice(1, -1), 10) : 0;
          date = new Date(now2.getTime() + step * (Number.isFinite(middle) && /^[+-]?\d+$/.test(name.slice(1, -1)) ? middle : 0));
        }
      } else if (reader.double("date") !== null) date = new Date(reader.double("date"));
      return { style, real, date };
    }
    function formatDate(reader) {
      const { style, real, date } = resolveDate(reader);
      const seconds = Math.round((date.getTime() - real.getTime()) / 1e3);
      const parts = (value) => {
        const total2 = Math.abs(value);
        const days = Math.floor(total2 / 86400);
        const hours2 = Math.floor(total2 % 86400 / 3600);
        const minutes2 = Math.floor(total2 % 3600 / 60);
        const secs2 = total2 % 60;
        if (days) return hours2 ? `${days} day${days === 1 ? "" : "s"}, ${hours2} hr` : `${days} day${days === 1 ? "" : "s"}`;
        if (hours2) return minutes2 ? `${hours2} hr, ${minutes2} min` : `${hours2} hr`;
        if (minutes2) return secs2 ? `${minutes2} min, ${secs2} sec` : `${minutes2} min`;
        return `${secs2} sec`;
      };
      if (style === "time") return date.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
      if (style === "date") return date.toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" });
      if (style === "relative") return parts(seconds);
      if (style === "offset") return `${seconds >= 0 ? "+" : "-"}${parts(seconds)}`;
      const total = Math.abs(seconds);
      const hours = Math.floor(total / 3600);
      const minutes = Math.floor(total % 3600 / 60);
      const secs = total % 60;
      return hours ? `${hours}:${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}` : `${minutes}:${String(secs).padStart(2, "0")}`;
    }
    function gridNode(element, reader, axis) {
      let items = [{ type: "adaptive", min: 30, max: null }];
      const columns = reader.string("columns");
      if (columns !== null) {
        try {
          const parsed = JSON.parse(columns);
          const stringValue = (value) => typeof value === "string" ? value : typeof value === "number" ? String(value) : "";
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
        } catch {
        }
      }
      if (items.length === 0) items = [{ type: "flexible" }];
      return new GridNode(axis, buildChildren(element, axis), { items, spacing: reader.double("spacing") ?? 8, alignment: reader.string("alignment") });
    }
    function arcPath(cx, cy, r, from, to) {
      const point = (angle) => [cx + r * Math.cos(angle * Math.PI / 180), cy + r * Math.sin(angle * Math.PI / 180)];
      const [x0, y0] = point(from);
      const [x1, y1] = point(to);
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
      let value = reader.string("value") !== null ? swiftDouble(reader.string("value")) ?? 0.6 : 0.6;
      if (reader.double("value") !== null) value = reader.double("value");
      value = Math.min(value, 1);
      const angle = Math.min(reader.string("angle") !== null ? swiftDouble(reader.string("angle")) ?? 260 : 260, 360);
      const thicknessText = reader.string("thickness");
      const thickness = thicknessText !== null && /^[+-]?\d+$/.test(thicknessText) ? Number(thicknessText) : 10;
      const fallback = primary();
      const needle = reader.string("needleColor") !== null ? color(reader.string("needleColor")) ?? fallback : fallback;
      let sections = [["green", 0.1], ["yellow", 0.1], ["orange", 0.1], ["red", 0.1], ["purple", 0.2], ["blue", 0.4]].map(([name, size2]) => ({ color: color(name), value: size2 }));
      if (reader.string("sections") !== null) {
        try {
          const parsed = JSON.parse(reader.string("sections"));
          if (Array.isArray(parsed)) {
            let left = 100;
            sections = parsed.map((item) => {
              const stringValue = (raw) => typeof raw === "string" ? raw : typeof raw === "number" ? String(raw) : "";
              let size2 = swiftDouble(stringValue(item?.value)) ?? 0;
              if (Math.trunc(size2 * 100) > left) size2 = 0;
              left -= Math.trunc(size2 * 100);
              return { color: color(stringValue(item?.color)) ?? fallback, value: size2 };
            });
          }
        } catch {
        }
      }
      const start = 90 + (360 - angle) / 2;
      const arcs = leaf(new FlexibleNode(), (node, element) => {
        const { width, height } = node.frame;
        if (width <= 0 || height <= 0) return;
        const lineWidth = height / thickness;
        const radius = (Math.min(width, height) - lineWidth) / 2;
        const cx = width / 2;
        const cy = height / 2;
        const svg = svgCanvas(element, width, height);
        let covered = 0;
        sections.forEach((section, index) => {
          const from = start + covered * angle;
          const to = from + section.value * angle;
          if (section.value > 0) svgElement(svg, "path", { d: arcPath(cx, cy, radius, from, to), fill: "none", stroke: cssColor(section.color), "stroke-width": lineWidth });
          const capAngle = index === 0 ? from : index === sections.length - 1 ? start + angle : null;
          if (capAngle !== null) {
            const rad = capAngle * Math.PI / 180;
            svgElement(svg, "circle", { cx: cx + radius * Math.cos(rad), cy: cy + radius * Math.sin(rad), r: lineWidth / 2, fill: cssColor(section.color) });
          }
          covered += section.value;
        });
        const needleAngle = start + value * angle;
        const group = svgElement(svg, "g", { transform: `rotate(${needleAngle} ${cx} ${cy})` });
        const rectWidth = height / 2;
        const rectHeight = height / 20;
        svgElement(group, "rect", { x: cx, y: cy - rectHeight / 2, width: rectWidth, height: rectHeight, rx: Math.min(lineWidth / 2, rectHeight / 2), fill: cssColor([needle[0], needle[1], needle[2], needle[3] * 0.8]) });
        svgElement(svg, "circle", { cx, cy, r: lineWidth / 2, fill: cssColor(needle) });
      });
      const labelFont = parseFont(reader.string("labelFont")) ?? defaultFont();
      const label = text(reader.string("label") ?? "60%", labelFont, paintOf(reader, "labelColor"));
      const title = text(reader.string("title") ?? "", labelFont, paintOf(reader, "titleColor"));
      return new BottomOverlayNode(arcs, new StackNode("v", [label, title], { alignment: "center", spacing: defaultSpacing("v") }));
    }
    function systemGauge(reader) {
      report("info", "tag.approximated", "<gauge type> system styles are approximated");
      const value = Math.max(0, Math.min(1, swiftDouble(reader.string("value") ?? "0.6") ?? 0.6));
      const style = reader.string("style") ?? "circular";
      const label = reader.string("text") ?? "";
      const current = reader.string("current") ?? "";
      const min = reader.string("min") ?? "";
      const max = reader.string("max") ?? "";
      const tintColor = cssColor(primary());
      const background = cssColor(systemBackground(appearance));
      if (style === "linear") {
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
        const radius = 25;
        const start = 135;
        const sweep = 270;
        svgElement(svg, "path", { d: arcPath(29, 29, radius, start, start + sweep), fill: "none", stroke: tintColor, "stroke-width": 5, "stroke-linecap": "round" });
        const angle = (start + sweep * value) * Math.PI / 180;
        svgElement(svg, "circle", { cx: 29 + radius * Math.cos(angle), cy: 29 + radius * Math.sin(angle), r: 3.5, fill: background, stroke: tintColor, "stroke-width": 1.5 });
      });
      const centerLabel = text(current, { size: 22, lineHeight: null, weight: 500, design: "default" }, null);
      const overlay = new ZStackNode([ringLeaf, centerLabel]);
      if (!label) return overlay;
      return new BottomOverlayNode(new FrameNode(overlay, { mode: "size", width: 58, height: 58, alignment: alignments.center }), text(label, styleFont("caption2"), null));
    }
    const chartPalette = ["blue", "green", "orange", "purple", "red", "cyan", "yellow", "brown"];
    function chartNode(reader) {
      report("info", "tag.approximated", "<chart> is drawn with an SVG approximation of Swift Charts");
      const type = reader.string("type") ?? "bar";
      const data = reader.string("data") ?? "";
      if (data === "") return text("#chart no data#", defaultFont(), null);
      let items;
      try {
        items = JSON.parse(data);
      } catch {
        return text("#chart data json invalid#", defaultFont(), null);
      }
      const gantt = type === "bar-gantt";
      const rule = type === "rule-x";
      const valid = Array.isArray(items) && items.every((item) => item && typeof item === "object" && (gantt ? typeof item.job === "string" && typeof item.start === "number" && typeof item.end === "number" : rule ? typeof item.xstart === "number" && typeof item.xend === "number" && typeof item.y === "number" : typeof item.label === "string" && typeof item.value === "number"));
      if (!["bar", "bar-x", "bar-y", "bar-gantt", "line", "point", "line-point", "area", "rect", "rule-x"].includes(type)) return text("#unknown chart type#", defaultFont(), null);
      if (!valid) return text("#chart data json invalid#", defaultFont(), null);
      const categoryEnabled = reader.bool("category") ?? false;
      const hideLegend = reader.bool("hideLegend") ?? false;
      const hideX = reader.bool("hideXAxis") ?? false;
      const hideY = reader.bool("hideYAxis") ?? false;
      const foreground = paintOf(reader, "color")?.color ?? color("blue");
      const categories = categoryEnabled ? [...new Set(items.map((item) => item.category ?? "null"))] : [];
      const colorFor = (item) => categoryEnabled ? color(chartPalette[categories.indexOf(item.category ?? "null") % chartPalette.length]) : foreground;
      const axisColor = cssColor(color("secondary"));
      return leaf(new FlexibleNode([200, 120]), (node, element) => {
        const { width, height } = node.frame;
        const svg = svgCanvas(element, width, height);
        const legendHeight = categoryEnabled && !hideLegend ? 14 : 0;
        const mac = platform() === "macos";
        const metrics = mac ? { top: 0, bottom: 0, xLabels: 18, yLabels: 20.5, yGap: 5, baseline: 14.5, yBaseline: 3.5, tick: 17.5, font: 10.5, labelBand: 0.9 } : { top: 0, bottom: 0, xLabels: 18, yLabels: 19, yGap: 6, baseline: 14, yBaseline: 3, tick: 16, font: 11, labelBand: 1 };
        const xLabelHeight = hideX ? 0 : metrics.xLabels;
        const yLabelWidth = hideY ? 0 : metrics.yLabels;
        const plot = { x: 0, y: metrics.top, width: Math.max(1, width - yLabelWidth), height: Math.max(1, height - xLabelHeight - legendHeight - metrics.top - metrics.bottom) };
        const textAt = (x, y, value, anchor = "middle") => {
          const label = svgElement(svg, "text", { x, y, "text-anchor": anchor, fill: axisColor, "font-size": metrics.font, "font-family": fontFamily(defaultFont()) });
          label.textContent = value;
          return label;
        };
        const values = gantt ? items.flatMap((item) => [item.start, item.end]) : rule ? items.flatMap((item) => [item.xstart, item.xend]) : items.map((item) => item.value);
        const stacked = type === "bar" ? Object.values(items.reduce((sums, item) => {
          sums[item.label] = (sums[item.label] ?? 0) + Math.max(0, item.value);
          return sums;
        }, {})) : [];
        const maxValue = Math.max(1e-9, ...values, ...stacked, 0);
        const magnitude = 10 ** Math.floor(Math.log10(maxValue));
        const tickStep = [0.1, 0.2, 0.5, 1, 2, 5, 10].map((factor) => factor * magnitude).find((candidate) => Math.ceil(maxValue / candidate - 1e-9) <= 4) ?? magnitude * 10;
        const valueAxisHidden = ["bar-x", "bar-y", "bar-gantt", "rule-x"].includes(type) ? hideX : hideY;
        const niceMax = valueAxisHidden ? maxValue : Math.ceil(maxValue / tickStep - 1e-9) * tickStep;
        const ticks = Array.from({ length: Math.round(niceMax / tickStep) + 1 }, (_, index) => index * tickStep);
        if (type === "bar" || type === "line" || type === "point" || type === "line-point" || type === "area" || type === "rect") {
          if (!hideY) for (const tick of ticks) {
            const y = plot.y + plot.height - tick / niceMax * plot.height;
            svgElement(svg, "line", { x1: plot.x, x2: plot.x + plot.width, y1: y, y2: y, stroke: axisColor, "stroke-opacity": 0.35 });
            textAt(plot.x + plot.width + metrics.yGap, y + metrics.yBaseline, Number(tick.toPrecision(3)).toString(), "start");
          }
          const labels = [...new Set(items.map((item) => item.label))];
          const band = plot.width / Math.max(1, labels.length);
          const xOf = (label) => plot.x + band * labels.indexOf(label) + band / 2;
          const yOf = (value) => plot.y + plot.height - Math.max(0, value) / niceMax * plot.height;
          if (!hideX) {
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
              if (type === "area") svgElement(svg, "path", { d: `M ${points[0][0]} ${plot.y + plot.height} ${points.map(([x, y]) => `L ${x} ${y}`).join(" ")} L ${points.at(-1)[0]} ${plot.y + plot.height} Z`, fill: stroke });
              else if (type !== "point") svgElement(svg, "polyline", { points: points.map((point) => point.join(",")).join(" "), fill: "none", stroke, "stroke-width": 2, "stroke-linejoin": "round" });
              if (type === "point" || type === "line-point") for (const [x, y] of points) svgElement(svg, "circle", { cx: x, cy: y, r: 3, fill: stroke });
            }
          }
        } else {
          const rows = gantt ? [...new Set(items.map((item) => item.job))] : rule ? [...new Set(items.map((item) => item.y))] : [null];
          const band = plot.height / Math.max(1, rows.length);
          const xOf = (value) => plot.x + Math.max(0, value) / niceMax * plot.width;
          if (!hideX) for (const tick of ticks) textAt(xOf(tick), plot.y + plot.height + 11, Number(tick.toPrecision(3)).toString());
          if (type === "bar-x" || type === "bar-y") {
            let offset = 0;
            for (const item of items) {
              const size2 = Math.max(0, item.value) / Math.max(1e-9, items.reduce((sum, entry) => sum + Math.max(0, entry.value), 0));
              if (type === "bar-x") svgElement(svg, "rect", { x: plot.x + offset * plot.width, y: plot.y, width: size2 * plot.width, height: plot.height, fill: cssColor(colorFor(item)) });
              else svgElement(svg, "rect", { x: plot.x, y: plot.y + plot.height - (offset + size2) * plot.height, width: plot.width, height: size2 * plot.height, fill: cssColor(colorFor(item)) });
              offset += size2;
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
    const modeFilters = {
      accented: { plain: "grayscale(1) brightness(1.15)", accent: "grayscale(1) sepia(1) saturate(4) hue-rotate(175deg) brightness(1.1)" },
      vibrant: { plain: "grayscale(1) brightness(1.25)", accent: "grayscale(1) brightness(1.25)" }
    };
    const snapToPixel = (value) => platform() === "macos" ? value : Math.round(value * 2) / 2;
    function draw(node, parent, accented = false, origin = [0, 0]) {
      const element = doc.createElement("div");
      const { width, height } = node.frame;
      const absolute = [origin[0] + node.frame.x, snapToPixel(origin[1] + node.frame.y)];
      const x = absolute[0] - origin[0];
      const y = absolute[1] - origin[1];
      Object.assign(element.style, { position: "absolute", left: `${x}px`, top: `${y}px`, width: `${width}px`, height: `${height}px` });
      let accent = accented;
      if (node instanceof DecorationNode) {
        accent ||= node.decoration.accentable === true;
        applyDecoration(element, node.decoration, width, height);
        if (modeFilters[renderingMode] && node.decoration.background) element.style.filter = [element.style.filter, modeFilters[renderingMode][accent ? "accent" : "plain"]].filter(Boolean).join(" ");
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
        element.dataset.swAnimation = JSON.stringify(animation.type === "swing" ? { kind: "swing", axis: animation.direction === "horizontal" ? "x" : "y", distance: swingDistance(animation.distance), duration: swingDuration(animation.duration) } : { kind: "clock", type: animation.type, timezone: animation.timezone, anchor: animation.anchor });
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
          style.setProperty("--sw-start-angle", `${angle}deg`);
          style.transform = `rotate(${angle}deg)`;
          const period = animation.type === "clock" ? 2 * Math.abs(clockPeriod(animation.interval)) : clockPeriods[animation.type];
          if (!frozen && Number.isFinite(period) && period <= 31536e3) {
            style.animation = `sw-clock ${period}s linear infinite`;
            if (animation.type === "clock" && animation.interval < 0) style.animationDirection = "reverse";
          }
        }
      }
      if (decoration.background?.color) style.backgroundColor = cssColor(decoration.background.color);
      else if (decoration.background?.gradient) style.backgroundImage = gradientCSS(decoration.background.gradient, width, height);
      if (decoration.cornerRadius !== void 0) {
        style.borderRadius = `${decoration.cornerRadius}px`;
        style.overflow = "hidden";
      }
      if (decoration.clip !== void 0) {
        const path = { circle: "circle(closest-side at 50% 50%)", ellipse: "ellipse(50% 50% at 50% 50%)", capsule: "inset(0 round 9999px)" }[decoration.clip];
        if (path) style.clipPath = path;
        else style.overflow = "hidden";
      }
      if (decoration.opacity !== void 0) style.opacity = String(decoration.opacity);
      if (decoration.transform) style.transform = decoration.transform;
      if (decoration.filter) style.filter = decoration.filter;
      if (decoration.border) style.boxShadow = `inset 0 0 0 1px ${cssColor(decoration.border)}`;
      if (decoration.dashed) {
        style.border = "1px dashed rgba(127,127,127,0.8)";
        style.boxSizing = "border-box";
      }
    }
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
        style.backgroundColor = "transparent";
        style.backgroundImage = "none";
        element.dataset.swMaterialFallback = "system";
        report("info", "material.system", "Local material is omitted in accented/vibrant mode; the system controls the widget background.");
      } else if (reduceTransparency || materialCount > 4 || cssSupported !== true) {
        style.backgroundColor = appearance === "dark" ? "black" : "white";
        if (fallback?.color) {
          const fill = cssColor(fallback.color);
          style.backgroundImage = `linear-gradient(${fill}, ${fill})`;
        } else if (fallback?.gradient) style.backgroundImage = gradientCSS(fallback.gradient, width, height);
        element.dataset.swMaterialFallback = "solid";
        report("info", "material.fallback", "Material uses an opaque background fallback (Reduce Transparency, unavailable CSS blur, or preview budget).");
      } else {
        style.backdropFilter = "blur(16px) saturate(140%)";
        style.webkitBackdropFilter = style.backdropFilter;
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
      if (platform() !== "macos") widget.style.webkitFontSmoothing = "antialiased";
      const rootPaint = parsePaint(propReader(root.props).string("background"), appearance);
      if (renderingMode === "fullColor" && !(lockScreen && family.startsWith("accessory"))) {
        if (rootPaint?.color) widget.style.backgroundColor = cssColor(rootPaint.color);
        else if (rootPaint?.gradient) widget.style.backgroundImage = gradientCSS(rootPaint.gradient, size.width, size.height);
        paintMaterial(widget, propReader(root.props).string("backgroundMaterial"), rootPaint, size.width, size.height);
      } else {
        widget.style.backgroundColor = renderingMode === "accented" ? "rgba(58, 64, 84, 1)" : "rgba(40, 40, 46, 1)";
        widget.style.colorScheme = "dark";
        if (renderingMode !== "fullColor") report("info", "mode.approximated", `${renderingMode} rendering mode is approximated`);
      }
      const keyframes = doc.createElement("style");
      const swingFrames = (axis) => Array.from({ length: 41 }, (_, index) => `${index * 2.5}%{transform:translate${axis}(calc(${Math.sin(index / 40 * 2 * Math.PI)} * var(--sw-swing)))}`).join("");
      keyframes.textContent = `@keyframes sw-clock{from{transform:rotate(var(--sw-start-angle))}to{transform:rotate(calc(var(--sw-start-angle) + 360deg))}}@keyframes sw-swing-X{${swingFrames("X")}}@keyframes sw-swing-Y{${swingFrames("Y")}}`;
      widget.appendChild(keyframes);
      draw(rootNode, widget);
      return { element: widget, size, diagnostics };
    } finally {
      setPlatform(previousPlatform);
      measurer.dispose();
    }
  }

  // core/src/main/js/render/entry.mjs
  var SVG_NAMESPACE = "http://www.w3.org/2000/svg";
  function createDocument(native) {
    class Style {
      setProperty(name, value) {
        this[name] = String(value);
      }
      getPropertyValue(name) {
        return this[name] ?? "";
      }
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
      appendChild(child) {
        this.children.push(child);
        return child;
      }
      replaceChildren(...children) {
        this.children = children;
        this.text = null;
      }
      remove() {
      }
      setAttribute(name, value) {
        this.attributes[name] = String(value);
      }
      getAttribute(name) {
        return Object.hasOwn(this.attributes, name) ? this.attributes[name] : null;
      }
      get textContent() {
        return this.text ?? "";
      }
      set textContent(value) {
        this.children = [];
        this.text = String(value);
      }
      set innerHTML(markup) {
        this.children = parseMarkup(markup);
        this.text = null;
      }
      querySelector(tag) {
        for (const child of this.children) {
          if (child.tagName === tag) return child;
          const found = child.querySelector?.(tag);
          if (found) return found;
        }
        return null;
      }
      set src(value) {
        this.attributes.src = String(value);
      }
      get src() {
        return this.attributes.src ?? "";
      }
      set alt(value) {
        this.attributes.alt = String(value);
      }
      set title(value) {
        this.attributes.title = String(value);
      }
      set className(value) {
        this.attributes.class = String(value);
      }
      // <img>: Kotlin reports the decoded size; decode() never loads anything.
      decode() {
        const size = JSON.parse(native("image.size", this.src) ?? "null");
        if (!size) return Promise.reject(new Error("Image could not be decoded"));
        this.naturalWidth = size[0];
        this.naturalHeight = size[1];
        return Promise.resolve();
      }
    }
    function parseMarkup(markup) {
      const roots = [];
      const stack = [];
      const tagPattern = /<(\/?)([A-Za-z][A-Za-z0-9]*)((?:\s+[A-Za-z_:][-A-Za-z0-9_:.]*\s*=\s*"[^"]*")*)\s*(\/?)>/g;
      const attributePattern = /([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*"([^"]*)"/g;
      let match;
      while ((match = tagPattern.exec(markup)) !== null) {
        const [, closing, name, attributes, selfClosing] = match;
        if (closing) {
          stack.pop();
          continue;
        }
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
      defaultView: void 0,
      body: null
    };
    document.body = new Element("body", false);
    return document;
  }
  function createMeasurer(native) {
    const cache = /* @__PURE__ */ new Map();
    const baselines = /* @__PURE__ */ new Map();
    const describe = (style) => ({ family: style.family, size: style.size, weight: style.weight, leading: style.leading, design: style.design ?? "default" });
    const measure = (text, style, width) => {
      const key = `${style.key}|${width}|${text}`;
      const cached = cache.get(key);
      if (cached) return cached;
      const result = JSON.parse(native("text.measure", JSON.stringify({ ...describe(style), text, width: width === null || width === Infinity ? null : width })));
      if (cache.size > 4e3) cache.clear();
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
      dispose() {
      }
    };
  }
  function serialize(node) {
    if (node.textNode !== void 0) return { x: node.textNode };
    const result = { t: node.tagName };
    if (node.svg) result.g = 1;
    const style = {};
    for (const key of Object.keys(node.style)) {
      const value = node.style[key];
      if (value !== "" && value !== void 0 && value !== null) style[key] = String(value);
    }
    if (Object.keys(style).length) result.s = style;
    if (Object.keys(node.attributes).length) result.a = node.attributes;
    if (Object.keys(node.dataset).length) result.d = node.dataset;
    if (node.text !== null) result.x = node.text;
    if (node.children.length) result.c = node.children.map(serialize);
    return result;
  }
  async function render(nativeCall, requestText) {
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
      resolveImageURL: (url) => /^data:image\/(png|jpeg|webp|gif);base64,/.test(url) || remote.has(url) ? url : null,
      // Android draws the first frame of a GIF.
      gifPreparer: async (url) => ({ url, firstFrame: url, info: {} })
    });
    return JSON.stringify({ width: size.width, height: size.height, root: serialize(element), diagnostics });
  }
  return __toCommonJS(entry_exports);
})();
