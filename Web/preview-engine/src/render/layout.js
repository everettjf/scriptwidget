// SwiftUI-style layout for the web renderer. Each node answers
// size(proposedWidth, proposedHeight) and is then placed at a final rect.
// Proposals follow SwiftUI: null = ideal size, 0 = minimum, Infinity =
// maximum, finite = offered space. Stacks distribute space to the least
// flexible children first, which is what makes text truncate and fixed
// content overflow the way it does on iPhone.
import { hyphenationPoints } from "./hyphenate.js";

export const sub = (value, amount) => (value === null || value === Infinity ? value : Math.max(0, value - amount));
const snap = (value) => Math.ceil(value * 2 - 1e-6) / 2;

export class Node {
  constructor() { this.frame = { x: 0, y: 0, width: 0, height: 0 }; }
  size() { return [0, 0]; }
  place(x, y, width, height) { this.frame = { x, y, width, height }; }
  edge() { return null; }
}

const cjk = /[\u2e80-\u9fff\uac00-\ud7af\uf900-\ufaff\uff00-\uffef]/u;

// One emoji: a pictograph with its variation selector, modifiers, and joined
// pictographs, or a flag.
const emojiCluster = /(\p{Extended_Pictographic}(?:\uFE0F|\u200D\p{Extended_Pictographic}|[\u{1F3FB}-\u{1F3FF}])*\uFE0F?|[\u{1F1E6}-\u{1F1FF}]{2})/u;

/// Break units of a paragraph: words, and each CJK character and emoji, which
/// break without a space (UAX #14 ID class). A unit keeps the separator that
/// precedes it, and closing punctuation stays with the unit before it.
function breakUnits(paragraph) {
  const units = [];
  for (const word of paragraph.split(/ +/).filter(Boolean)) {
    const byEmoji = emojiCluster.test(word) ? word.split(emojiCluster).filter(Boolean) : [word];
    const pieces = byEmoji.flatMap((part) => (cjk.test(part) ? part.split(/(?=[\u2e80-\u9fff\uac00-\ud7af\uf900-\ufaff])/u).filter(Boolean) : [part]));
    pieces.forEach((piece, index) => {
      const separator = index === 0 ? " " : "";
      if (units.length && /^[:;,.!?)\]}%，。！？、：；）」』]/.test(piece)) units[units.length - 1].text += separator + piece;
      else units.push({ text: piece, separator });
    });
  }
  return units;
}

const joinUnits = (line) => line.map((unit, index) => (index === 0 ? unit.text : unit.separator + unit.text)).join("");

/// Text: one line is the natural height; extra lines advance by `leading`.
export class TextNode extends Node {
  constructor(text, style, measurer) {
    super();
    this.text = text; this.style = style; this.measurer = measurer;
  }
  /// When every word fits, the standard line break strategy may push a word
  /// down (see pushOut). A word wider than the line breaks between
  /// characters, as the browser does, except that iOS text styles (Dynamic
  /// Type fonts, style.hyphenate) hyphenate it at the longest dictionary
  /// break that fits ("Depar- / ture gate").
  displayText(width) {
    if (width === null || width === Infinity || width <= 0) return this.text;
    const key = `${width}`;
    this.hyphenated ??= new Map();
    if (this.hyphenated.has(key)) return this.hyphenated.get(key);
    // No break before closing punctuation (UAX #14), which browsers allow
    // after a space: a no-break space keeps "Size :" together.
    const broken = this.text.split("\n").map((paragraph) => this.pushOut(paragraph, width)).join("\n");
    const pushed = broken.replace(/ (?=[:;!?%)\]}，。！？、：；）」』])/g, "\u00a0");
    if (this.style.hyphenate === false || broken !== this.text) {
      this.hyphenated.set(key, pushed);
      return pushed;
    }
    const fits = (piece) => this.measurer.measure(piece, this.style, null).width <= width + 0.01;
    const result = pushed.replace(/[^\s]+/g, (word) => {
      if (fits(word)) return word;
      // Only the letters of a word hyphenate; punctuation stays attached.
      const [, lead, core, tail] = /^([^A-Za-z]*)([A-Za-z]*)(.*)$/s.exec(word);
      const points = hyphenationPoints(core).map((point) => point + lead.length);
      const pieces = [];
      let rest = word; let consumed = 0;
      while (!fits(rest)) {
        // The longest prefix that fits with a hyphen; without one the word
        // breaks between characters.
        const point = points.filter((value) => value > consumed && value < consumed + rest.length && fits(`${word.slice(consumed, value)}-`)).at(-1);
        if (point === undefined) break;
        pieces.push(`${word.slice(consumed, point)}-`);
        rest = word.slice(point);
        consumed = point;
      }
      pieces.push(rest);
      return tail === undefined ? word : pieces.join("\n");
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
      if (!line.length || fits([...line, word])) line.push(word); else lines.push([word]);
    }
    if (lines.length !== 2) return paragraph;
    const [first, last] = lines;
    if (last.length !== 1 || last[0].text.includes(" ") || first.length < 2) return paragraph;
    const moved = [first.at(-1), ...last];
    const rest = first.slice(0, -1);
    if (!fits(moved) || measure(rest) < measure(moved) * 0.55) return paragraph;
    return `${join(rest)}\n${join(moved)}`;
  }

  /// SwiftUI keeps breaking a word one character per line in a column
  /// narrower than "…" as long as its first character fits.
  /// Whether a height proposal leaves room for a single line only.
  oneLine(ph) {
    return ph !== null && ph !== Infinity && ph < this.style.natural + this.style.leading - 1e-6;
  }
  wrapsCharacters(width) {
    const first = [...this.text.trim()][0];
    return first !== undefined && this.measurer.measure(first, this.style, null).width <= width + 0.01;
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
        if (fits(joinUnits([...line, unit]))) { line.push(unit); continue; }
        if (line.length) lines.push(joinUnits(line));
        line = [];
        let piece = "";
        for (const character of [...unit.text]) {
          if (piece && !fits(piece + character)) { lines.push(piece); piece = character; } else piece += character;
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
    let low = 0; let high = characters.length;
    while (low < high) { const middle = Math.ceil((low + high) / 2); if (fits(middle)) low = middle; else high = middle - 1; }
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
    const advance = next === undefined || next === " " || prefix === "" ? measure(prefix) : measure(prefix + next) - measure(next);
    return advance + this.measurer.ellipsisWidth(this.style);
  }
  /// SwiftUI truncation to `count` lines: earlier lines stay as broken, the
  /// rest is cut mid-word with "…", and the text reports the widest drawn
  /// line (not the offered width).
  truncate(width, count) {
    const lines = this.breakLines(width);
    if (lines.length <= count) return null;
    const kept = lines.slice(0, count - 1);
    // The truncated line cuts the original text after the kept lines, so it
    // carries no inserted hyphen ("REM…", "An- / gula…").
    let position = 0;
    for (const line of kept) {
      for (const character of line.replace(/-$/, "")) {
        while (position < this.text.length && /\s/.test(this.text[position]) && !/\s/.test(character)) position += 1;
        // Characters may be surrogate pairs (emoji): compare and advance by
        // their UTF-16 length.
        if (this.text.startsWith(character, position)) position += character.length;
        else if (character === "\u00a0" && this.text[position] === " ") position += 1;
      }
    }
    const rest = this.text.slice(position).trimStart();
    const last = this.ellipsize(rest, width);
    const drawn = [...kept, last];
    const restCharacters = [...rest.replace(/\n/g, " ")];
    const lastWidth = this.truncatedWidth(restCharacters, [...last].length - 1);
    return { text: drawn.join("\n"), width: Math.max(lastWidth, ...kept.map((line) => this.measurer.measure(line, this.style, null).width)) };
  }
  metrics(width) { return this.measurer.measure(width === null ? this.text : this.displayText(width), this.style, width); }
  layout(pw, ph) {
    const { natural, leading } = this.style;
    if (this.text === "") return { width: 0, height: 0, lines: 0, total: 0 };
    let width; let lines;
    // Offered no width at all, SwiftUI draws nothing.
    if (pw !== null && pw <= 0.01) return { width: 0, height: natural, lines: 1, total: 1, text: "" };
    if (pw === null || pw === Infinity) { const m = this.metrics(null); width = m.width; lines = m.lines; }
    // Narrower than "…": with room for one line, SwiftUI draws the text
    // itself unwrapped and clipped ("Bl" for BEIJING in 9 points); with room
    // for more lines and not even the first character fitting, a clipped "…".
    else if (pw < this.measurer.ellipsisWidth(this.style) && (this.oneLine(ph) || !this.wrapsCharacters(pw))) {
      const text = this.text.trim() === "" ? "" : this.oneLine(ph) ? this.text.split("\n")[0] : "…";
      return { width: snap(pw), height: natural, lines: 1, total: 1, text, clip: true };
    }
    else {
      // Offered at least the natural width: keep the unwrapped layout rather
      // than re-measuring at an explicit width, which can wrap on sub-pixel
      // differences.
      const free = this.metrics(null);
      if (pw >= free.width - 0.01) { width = free.width; lines = free.lines; }
      else { const m = this.metrics(pw); width = Math.min(pw, m.width); lines = m.lines; }
    }
    const total = lines;
    if (ph !== null && ph !== Infinity) lines = Math.min(lines, Math.max(1, Math.floor((ph - natural) / leading + 1e-6) + 1));
    let text = null;
    if (lines < total && pw !== null && pw !== Infinity && pw >= this.measurer.ellipsisWidth(this.style)) {
      const truncated = this.truncate(pw, lines);
      if (truncated) { text = truncated.text; width = truncated.width; }
    }
    return { width: snap(width), height: natural + (lines - 1) * leading, lines, total, text };
  }
  size(pw, ph) { const { width, height } = this.layout(pw, ph); return [width, height]; }
  place(x, y, width, height) { super.place(x, y, width, height); this.lines = this.layout(width, height); }
  edge() { return this.style; }
}

/// Shapes, colors, and resizable images take whatever they are offered.
export class FlexibleNode extends Node {
  constructor(ideal = [10, 10]) { super(); this.ideal = ideal; }
  size(pw, ph) { return [pw ?? this.ideal[0], ph ?? this.ideal[1]]; }
}

/// Fixed intrinsic size (non-resizable images, glyphs, fixed controls).
export class FixedNode extends Node {
  constructor(width, height) { super(); this.width = width; this.height = height; }
  size() { return [this.width, this.height]; }
}

/// Spacer: flexible along its stack axis with a minimum length, empty across.
export class SpacerNode extends Node {
  constructor(axis, minLength = 8) { super(); this.axis = axis; this.minLength = minLength; this.isSpacer = true; }
  size(pw, ph) {
    const along = (proposal) => (proposal === null ? this.minLength : Math.max(this.minLength, proposal));
    if (this.axis === "h") return [along(pw), 0];
    if (this.axis === "v") return [0, along(ph)];
    return [along(pw), along(ph)];
  }
}

/// Image with aspectRatio(ratio, contentMode) inside its proposal.
export class AspectNode extends Node {
  constructor(natural, ratio, mode) { super(); this.natural = natural; this.ratio = ratio ?? natural[0] / Math.max(natural[1], 1e-9); this.mode = mode; }
  size(pw, ph) {
    if (pw === null && ph === null) return this.natural;
    const w = pw ?? (ph === null || ph === Infinity ? this.natural[0] : ph * this.ratio);
    const h = ph ?? (pw === null || pw === Infinity ? this.natural[1] : pw / this.ratio);
    if (w === Infinity || h === Infinity) return [w === Infinity ? (h === Infinity ? Infinity : h * this.ratio) : w, h === Infinity ? (w === Infinity ? Infinity : w / this.ratio) : h];
    const fitWidth = Math.min(w, h * this.ratio);
    const fillWidth = Math.max(w, h * this.ratio);
    const width = this.mode === "fill" ? fillWidth : fitWidth;
    return [width, width / this.ratio];
  }
}

/// The offer to re-propose to a child while placing: SwiftUI places
/// subviews with the proposal they were sized with, so a view that came out
/// smaller than offered (text that fit in fewer lines) is not re-offered only
/// its final size, which could make a text that needed the room truncate.
const placementOffer = (final, proposed) => (proposed !== null && proposed !== undefined && proposed !== Infinity && proposed > final ? proposed : final);

export class PaddingNode extends Node {
  constructor(child, [top, trailing, bottom, leading]) { super(); this.child = child; this.insets = { top, trailing, bottom, leading }; }
  size(pw, ph) {
    this.proposal = [pw, ph];
    const { top, trailing, bottom, leading } = this.insets;
    const [w, h] = this.child.size(sub(pw, leading + trailing), sub(ph, top + bottom));
    return [w + leading + trailing, h + top + bottom];
  }
  place(x, y, width, height) {
    super.place(x, y, width, height);
    const { top, trailing, bottom, leading } = this.insets;
    const innerW = Math.max(0, width - leading - trailing); const innerH = Math.max(0, height - top - bottom);
    const [pw, ph] = this.proposal ?? [width, height];
    const [w, h] = this.child.size(placementOffer(innerW, sub(pw, leading + trailing)), placementOffer(innerH, sub(ph, top + bottom)));
    this.child.place(leading + (innerW - w) / 2, top + (innerH - h) / 2, w, h);
  }
}

const alignOffset = (space, size, where) => (where === "start" ? 0 : where === "end" ? space - size : (space - size) / 2);

/// frame(width:height:alignment:) and frame(maxWidth: .infinity, ...).
export class FrameNode extends Node {
  constructor(child, { mode, width, height, alignment }) { super(); this.child = child; this.mode = mode; this.width = width; this.height = height; this.alignment = alignment; }
  size(pw, ph) {
    this.proposal = [pw, ph];
    if (this.mode === "max") {
      const [cw, ch] = this.child.size(pw, ph);
      return [pw === null ? cw : pw, ph === null ? ch : ph];
    }
    const fixedW = this.mode === "size" || this.mode === "width" ? this.width : null;
    const fixedH = this.mode === "size" || this.mode === "height" ? this.height : null;
    const [cw, ch] = this.child.size(fixedW ?? pw, fixedH ?? ph);
    return [fixedW ?? cw, fixedH ?? ch];
  }
  place(x, y, width, height) {
    super.place(x, y, width, height);
    // Fixed dimensions offer exactly their length; the others re-offer what
    // the frame itself was offered.
    const [pw, ph] = this.proposal ?? [width, height];
    const fixedW = this.mode === "size" || this.mode === "width"; const fixedH = this.mode === "size" || this.mode === "height";
    const [w, h] = this.child.size(fixedW ? width : placementOffer(width, pw), fixedH ? height : placementOffer(height, ph));
    const [horizontal, vertical] = this.alignment;
    this.child.place(alignOffset(width, w, horizontal), alignOffset(height, h, vertical), w, h);
  }
}

/// Background, corner radius, clipping, opacity, transforms, shadow: same
/// size as the content.
export class DecorationNode extends Node {
  constructor(child, decoration) { super(); this.child = child; this.decoration = decoration; }
  size(pw, ph) { return this.child.size(pw, ph); }
  place(x, y, width, height) { super.place(x, y, width, height); this.child.place(0, 0, width, height); }
  edge(side) { return this.decoration.keepsEdges ? this.child.edge(side) : null; }
}

/// HStack / VStack.
export class StackNode extends Node {
  constructor(axis, children, { alignment, spacing }) {
    super();
    this.axis = axis; this.children = children; this.alignment = alignment;
    this.spacing = children.map((child, index) => (index === 0 ? 0 : spacing(children[index - 1], child)));
  }
  along(size) { return this.axis === "h" ? size[0] : size[1]; }
  cross(size) { return this.axis === "h" ? size[1] : size[0]; }
  propose(child, along, cross) { return this.axis === "h" ? child.size(along, cross) : child.size(cross, along); }
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
    }).sort((a, b) => a.flexibility - b.flexibility || a.index - b.index);
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
    // Remembered for place(): the parent's last call is the real offer.
    this.proposal = [pw, ph];
    const pAlong = this.axis === "h" ? pw : ph; const pCross = this.axis === "h" ? ph : pw;
    const sizes = this.allocate(pAlong, pCross);
    const along = sizes.reduce((sum, size) => sum + this.along(size), 0) + this.spacing.reduce((sum, value) => sum + value, 0);
    const cross = sizes.reduce((max, size) => Math.max(max, this.cross(size)), 0);
    return this.axis === "h" ? [along, cross] : [cross, along];
  }
  place(x, y, width, height) {
    super.place(x, y, width, height);
    // SwiftUI places subviews with the proposal the stack was sized with:
    // along the axis children get the same offers as when sizing (an HStack
    // narrower than its proposal does not squeeze them), and across it a
    // stack that grew past its proposal because a child cannot shrink (a
    // 120-point line in a 72-point widget) lays out the others within it.
    const [pw, ph] = this.proposal ?? [width, height];
    const proposedAlong = this.axis === "h" ? pw : ph;
    const proposedCross = this.axis === "h" ? ph : pw;
    const finalCross = this.axis === "h" ? height : width;
    const rigid = (limit) => this.children.some((child) => this.cross(this.propose(child, null, 0)) > limit + 0.01);
    const pAlong = proposedAlong;
    // A stack that came out shorter across than offered (texts that fit in
    // fewer lines) places its children with that same offer too: offering
    // only its final size would make a text that needed the room truncate.
    const offered = proposedCross !== null && proposedCross !== Infinity;
    const pCross = offered && (finalCross < proposedCross - 0.01 || (finalCross > proposedCross + 0.01 && rigid(proposedCross))) ? proposedCross : finalCross;
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
}

/// A vertically scrolling list (Android). It takes the size it is offered and
/// stacks its rows at their natural heights, past its own bottom edge when
/// they do not all fit; the host scrolls them.
export class ListNode extends Node {
  constructor(children, spacing) { super(); this.children = children; this.spacing = Math.max(0, spacing); this.contentHeight = 0; }
  size(pw, ph) {
    const offered = (value) => value !== null && value !== Infinity;
    if (offered(pw) && offered(ph)) return [pw, ph];
    const sizes = this.children.map((child) => child.size(offered(pw) ? pw : null, null));
    const width = offered(pw) ? pw : sizes.reduce((widest, size) => Math.max(widest, size[0]), 0);
    const height = offered(ph) ? ph : sizes.reduce((sum, size) => sum + size[1], 0) + this.spacing * Math.max(0, sizes.length - 1);
    return [width, height];
  }
  place(x, y, width, height) {
    super.place(x, y, width, height);
    let cursor = 0;
    this.children.forEach((child, index) => {
      if (index > 0) cursor += this.spacing;
      const [w, h] = child.size(width, null);
      child.place(0, cursor, w, h);
      cursor += h;
    });
    this.contentHeight = cursor;
  }
}

function mergedEdge(children, side) {
  // The largest text edge wins; SF Symbol edges count only without text.
  const edges = children.map((child) => child.edge(side)).filter(Boolean);
  const text = edges.filter((edge) => !edge.symbol);
  return (text.length ? text : edges).reduce((best, edge) => (!best || edge.size > best.size ? edge : best), null);
}

export class ZStackNode extends Node {
  constructor(children) { super(); this.children = children; }
  edge(side) { return mergedEdge(this.children, side); }
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
}

/// LazyVGrid / LazyHGrid: columns (or rows) from fixed, flexible, and
/// adaptive items; cells are centered and lines take their tallest cell.
export class GridNode extends Node {
  constructor(axis, children, { items, spacing, alignment }) {
    super();
    this.axis = axis; this.children = children; this.items = items; this.spacing = spacing; this.alignment = alignment;
    // LazyVGrid/LazyHGrid's spacing separates rows (columns of an HGrid);
    // tracks are separated by each GridItem's spacing, which ScriptWidget
    // leaves at the system default of 8 points.
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
    const extents = lines.map((line) => Math.max(...line.map(({ size }) => (this.axis === "v" ? size[1] : size[0]))));
    return { tracks, lines, extents };
  }
  size(pw, ph) {
    const { tracks, extents } = this.arrange(this.axis === "v" ? pw : ph);
    const along = tracks.reduce((sum, value) => sum + value, 0) + this.trackSpacing * Math.max(0, tracks.length - 1);
    const cross = extents.reduce((sum, value) => sum + value, 0) + this.spacing * Math.max(0, extents.length - 1);
    const width = this.axis === "v" ? (pw === null || pw === Infinity ? along : pw) : cross;
    const height = this.axis === "v" ? cross : (ph === null || ph === Infinity ? along : ph);
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
}

// Apple Color Emoji in CoreText (SwiftUI on macOS 27; WebKit matches it), for
// font sizes 1...160: the advance of one glyph and the width it is drawn at.
// Small sizes draw the glyph larger than the font size and leave about a point
// on each side. Chrome draws emoji at exactly 1 em, so the measurer resizes
// and pads emoji runs where the browser differs.
const emojiAdvances = [1,3,4,6,7,9,10,12,13,14,16,17,19,20,21,23,23,24,24,25,26,26,27,27,28,30,31,32,33,34,35,36,37,38,40,41,42,43,44,45,46,47,48,49,50,50,51,52,53,54,55,56,57,58,59,61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,79,80,81,82,83,84,85,86,87,88,89,91,92,93,94,95,96,97,98,99,100,101,102,104,105,106,107,108,109,110,111,112,113,114,116,117,118,119,120,121,122,123,124,125,127,128,129,130,131,132,133,134,135,136,137,139,140,141,142,143,144,145,146,147,148,150,151,152,153,154,155,156,157,158,159,161,162,163,164,165,166,167,168,169,171,172,173,174];
const emojiGlyphs = [1,2.5,4,5,6.5,7.5,9,10,11.5,12.5,14,15,16.5,17.5,19,20,20.5,21,21.5,22,22.5,23,23.5,24,24.5,25.5,26.5,27.5,28.5,29.5,30.5,31.5,32.5,33.5,34.5,35.5,36.5,37.5,38.5,39.5,40.5,41.5,42.5,43.5,44.5,45.5,46.5,47.5,48.5,49.5,50.5,51.5,52.5,53.5,54.5,55.5,56.5,57.5,58.5,59.5,60.5,61.5,62.5,63.5,64.5,65.5,66,66.5,67.5,68.5,69.5,70.5,71.5,72.5,73.5,74.5,75.5,76.5,77.5,78.5,79.5,80.5,81.5,82.5,83.5,84.5,85.5,86.5,87.5,88.5,89.5,90.5,91.5,92.5,93.5,94.5,95.5,96.5,97.5,98.5,99.5,100.5,101.5,102.5,103.5,104.5,105.5,106.5,107.5,108.5,109.5,110.5,111.5,112,113,114,115,116,117,118,119,120,121,122,123,124,125,126,127,128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143,144,145,146,147,148,149,150,151,152,153,154,155,156,157,158];
const emojiRun = /(\p{Extended_Pictographic}(?:\uFE0F|\u200D\p{Extended_Pictographic}|[\u{1F3FB}-\u{1F3FF}])*|[\u{1F1E6}-\u{1F1FF}]{2})/u;

// Advance of one Han ideograph in CoreText's system font (PingFang through
// the SF cascade) for font sizes 1...160; weight and design do not change it.
// Browsers draw these glyphs at their own advance (Chrome tracks them
// differently), so the measurer letter-spaces Han runs to match.
const hanAdvances = [0.994,1.988,2.982,3.977,4.971,5.965,6.959,7.953,8.947,9.942,10.936,11.918,12.899,13.891,14.883,15.875,16.851,17.842,18.834,19.154,20.053,20.945,21.898,22.85,23.802,24.754,25.706,26.658,27.583,28.506,29.427,30.346,31.263,32.211,33.158,34.105,35.018,35.964,36.911,37.82,38.765,39.711,40.656,41.56,42.505,43.449,44.35,45.293,46.237,47.18,48.124,49.068,50.011,50.955,51.898,52.842,53.786,54.729,55.673,56.617,57.56,58.504,59.447,60.391,61.335,62.278,63.222,64.165,65.109,66.053,66.996,67.94,68.883,69.827,70.771,71.714,72.658,73.602,74.545,75.489,76.432,77.376,78.32,79.263,80.207,81.15,82.094,83.038,83.981,84.925,85.868,86.812,87.756,88.699,89.643,90.586,91.53,92.474,93.417,94.361,95.305,96.248,97.192,98.135,99.079,100.023,100.966,101.91,102.853,103.797,104.741,105.684,106.628,107.571,108.515,109.459,110.402,111.346,112.289,113.233,114.177,115.12,116.064,117.008,117.951,118.895,119.838,120.782,121.726,122.669,123.613,124.556,125.5,126.444,127.387,128.331,129.274,130.218,131.162,132.105,133.049,133.992,134.936,135.88,136.823,137.767,138.711,139.654,140.598,141.541,142.485,143.429,144.372,145.316,146.259,147.203,148.147,149.09,150.034,150.977];
const hanRun = /(\p{Script=Han}+)/u;
const hanAdvance = (size) => {
  const index = Math.min(hanAdvances.length, Math.max(1, size)) - 1;
  const low = Math.floor(index); const high = Math.min(hanAdvances.length - 1, low + 1);
  const value = hanAdvances[low] + (hanAdvances[high] - hanAdvances[low]) * (index - low);
  return size > hanAdvances.length ? value * size / hanAdvances.length : value;
};

/// Sets element's text, drawing emoji runs with `adjust.emoji` ({fontSize,
/// padding} in px) and Han runs with `adjust.han` ({letterSpacing} in px),
/// both from the measurer, when the browser needs adjusting.
export function fillText(element, text, adjust) {
  const emoji = adjust?.emoji && emojiRun.test(text) ? adjust.emoji : null;
  const han = adjust?.han && hanRun.test(text) ? adjust.han : null;
  if (!emoji && !han) { element.textContent = text; return; }
  const doc = element.ownerDocument;
  const pattern = new RegExp(`${emoji ? emojiRun.source : "(?!)"}|${han ? hanRun.source : "(?!)"}`, "u");
  element.replaceChildren(...text.split(pattern).filter((part) => part !== undefined && part !== "").map((part) => {
    const span = doc.createElement("span");
    if (emoji && emojiRun.test(part)) Object.assign(span.style, { fontSize: `${emoji.fontSize}px`, lineHeight: "0", padding: `0 ${emoji.padding}px`, position: "relative", top: `${emoji.drop}px` });
    else if (han && hanRun.test(part)) span.style.letterSpacing = `${han.letterSpacing}px`;
    else return doc.createTextNode(part);
    span.textContent = part;
    return span;
  }));
}

/// Measures text with the browser's line breaker. Results are cached.
export function createTextMeasurer(doc) {
  const host = doc.createElement("div");
  Object.assign(host.style, { position: "absolute", left: "-100000px", top: "0", visibility: "hidden", contain: "layout style" });
  const probe = doc.createElement("div");
  probe.style.whiteSpace = "pre-wrap";
  probe.style.overflowWrap = "break-word";
  host.appendChild(probe);
  doc.body.appendChild(host);
  const cache = new Map();
  const apply = (style) => {
    probe.style.fontFamily = style.family; probe.style.fontSize = `${style.size}px`;
    probe.style.fontWeight = String(style.weight); probe.style.lineHeight = `${style.leading}px`;
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
  // How to draw emoji so each glyph is as wide and advances as far as in
  // CoreText, or null when the browser already matches (WebKit).
  const emojiStyles = new Map();
  function emojiSize(style) {
    if (emojiStyles.has(style.key)) return emojiStyles.get(style.key);
    apply(style);
    probe.style.width = "max-content";
    probe.textContent = "\u{1F420}";
    const measured = probe.getBoundingClientRect().width;
    const index = Math.round(style.size) - 1;
    const advance = emojiAdvances[index] ?? style.size * 1.09;
    const glyph = emojiGlyphs[index] ?? style.size;
    // Browsers that differ draw the glyph as wide as its advance.
    // CoreText enlarges small emoji around their middle; resized in the
    // browser they would grow up from the baseline, so drop them by half
    // the enlargement.
    const result = measured > 0 && Math.abs(measured - advance) > 0.5
      ? { fontSize: style.size * glyph / measured, padding: Math.max(0, (advance - glyph) / 2), drop: Math.max(0, (glyph - style.size) / 2) }
      : null;
    emojiStyles.set(style.key, result);
    return result;
  }
  // How far to letter-space Han runs so each ideograph advances as far as in
  // CoreText, or null when the browser already matches.
  const hanStyles = new Map();
  function hanSpacing(style) {
    if (hanStyles.has(style.key)) return hanStyles.get(style.key);
    apply(style);
    probe.style.width = "max-content";
    probe.textContent = "\u4ECA".repeat(10);
    const measured = probe.getBoundingClientRect().width / 10;
    const delta = hanAdvance(style.size) - measured;
    const result = measured > 0 && Math.abs(delta) > 0.02 ? { letterSpacing: delta } : null;
    hanStyles.set(style.key, result);
    return result;
  }
  const textAdjustments = (style) => ({ emoji: emojiSize(style), han: hanSpacing(style) });
  // Where the browser draws the first baseline below the top of a line box
  // of the style's leading (fonts round their metrics differently).
  const baselines = new Map();
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
    dispose() { host.remove(); },
  };
}
