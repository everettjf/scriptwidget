import { javascriptLanguage } from "@codemirror/lang-javascript";
import { scriptWidgetAPI } from "./scriptWidgetAPI.js";

// Source ranges are the model. Opening/exporting never regenerates JavaScript.
// Edits are explicit, bounded transactions against exactly the parsed source.
const parser = javascriptLanguage.parser.configure({ dialect: "jsx" });
const names = new Map(Object.keys(scriptWidgetAPI.components).map(name => [name.toLowerCase(), name]));
const containers = new Set(["VStack", "HStack", "ZStack", "VGrid", "HGrid"]);
const maximumSource = 512 * 1024, maximumNodes = 512, maximumDepth = 32;
const children = node => { const result = []; for (let child = node.firstChild; child; child = child.nextSibling) result.push(child); return result; };
const slice = (source, node) => source.slice(node.from, node.to);
const fail = message => { throw new Error(message); };
const textEntity = raw => {
  let valid = true;
  const value = raw.replace(/&([^;\s]+);/g, (whole, name) => {
    const common = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: "\u00a0" };
    if (Object.hasOwn(common, name)) return common[name];
    if (/^#(?:[0-9]+|x[0-9a-f]+)$/i.test(name)) {
      const number = name[1].toLowerCase() === "x" ? parseInt(name.slice(2), 16) : Number(name.slice(1));
      if (number > 0 && number <= 0x10ffff && !(number >= 0xd800 && number <= 0xdfff)) return String.fromCodePoint(number);
    }
    valid = false; return whole;
  });
  return valid ? value : undefined;
};
// Lines of the source, for edits that add, move or remove whole lines.
const lineStart = (source, at) => source.lastIndexOf("\n", at - 1) + 1;
const lineEnd = (source, at) => { const end = source.indexOf("\n", at); return end < 0 ? source.length : end; };
const blank = text => !/\S/.test(text);
// The lines a range fills when nothing else is written on them, else null.
function wholeLines(source, from, to) {
  const start = lineStart(source, from), end = lineEnd(source, to);
  if (!blank(source.slice(start, from)) || !blank(source.slice(to, end))) return null;
  return { start, end: Math.min(end + 1, source.length), indent: source.slice(start, from) };
}
// The same lines at another indentation; the first line carries none.
const reindent = (text, from, to) => from === null ? text
  : text.split("\n").map((line, index) => index && line.startsWith(from) ? to + line.slice(from.length) : line).join("\n");
function literal(raw, jsx = false) {
  if (jsx) return textEntity(raw.slice(1, -1));
  const value = raw.trim();
  if (/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/.test(value)) { const n = Number(value); return Number.isFinite(n) ? n : undefined; }
  if (value === "true" || value === "false") return value === "true";
  if (value.startsWith('"')) { try { const parsed = JSON.parse(value); return typeof parsed === "string" ? parsed : undefined; } catch { /* Not a JSON string literal. */ } }
  return undefined;
}

export function parseVisualLayout(source) {
  const model = { formatVersion: 1, source, nodes: [], roots: [], issue: "" };
  if (typeof source !== "string" || new TextEncoder().encode(source).length > maximumSource) return { ...model, issue: "Layout editing supports source files up to 512 KiB." };
  // The grammar does not read a JSX comment child, `{/* … */}`, and reports
  // the rest as a syntax error. Parse a copy in which each one is `{0   }` of
  // the same length, and leave those children out below. Ranges are unchanged,
  // and everything shown or edited is still read from `source`.
  const comments = new Set();
  const parsedText = source.replace(/\{\s*(?:\/\*[\s\S]*?\*\/\s*)+\}/g, (whole, offset) => {
    comments.add(offset);
    return `{0${whole.slice(2, -1).replace(/[^\r\n]/g, " ")}}`;
  });
  const tree = parser.parse(parsedText);
  let syntaxError = false;
  tree.iterate({ enter: node => { if (node.type.isError) syntaxError = true; } });
  if (syntaxError) return { ...model, issue: "Fix the JavaScript/JSX syntax before using Layout. Your source is preserved." };
  function element(node, parentID, depth) {
    if (depth > maximumDepth || model.nodes.length >= maximumNodes) fail("Layout editing supports up to 512 layers and 32 nesting levels.");
    const parts = children(node), opening = parts[0], closing = parts.at(-1);
    const nameNode = children(opening).find(child => ["JSXBuiltin", "JSXIdentifier", "JSXNamespacedName", "JSXMemberExpression"].includes(child.name));
    const tag = nameNode ? slice(source, nameNode) : "Fragment";
    const component = names.get(tag.toLowerCase()), definition = scriptWidgetAPI.components[component];
    const ownProperties = { ...scriptWidgetAPI.globalProperties, ...(definition?.properties ?? {}) };
    const paired = opening.name === "JSXOpenTag" && closing?.name === "JSXCloseTag";
    const closingName = paired ? children(closing).find(child => ["JSXBuiltin", "JSXIdentifier", "JSXNamespacedName", "JSXMemberExpression"].includes(child.name)) : null;
    if (nameNode && paired && (!closingName || slice(source, closingName) !== tag)) fail("Opening and closing JSX tags must match before using Layout.");
    const row = { id: String(node.from), parentID, tag, component: component ?? null, from: node.from, to: node.to,
      openingEnd: opening.to, insertAt: opening.to - (paired ? 1 : 2), contentFrom: opening.to, contentTo: paired ? closing.from : opening.to,
      children: [], properties: [], locked: !definition, structure: false, text: null, textEditable: false, depth,
      // Where the comment written just above this layer starts; the layer's own start when there is none.
      outerFrom: node.from, textFrom: 0, textTo: 0 };
    let spread = false;
    for (const child of children(opening)) {
      if (child.name === "JSXSpreadAttribute") spread = true;
      if (child.name !== "JSXAttribute") continue;
      const segments = children(child), key = slice(source, segments[0]), input = segments[2];
      const value = !input ? true : literal(slice(source, input), input.name === "JSXAttributeValue");
      const expression = input?.name === "JSXEscape" ? literal(source.slice(input.from + 1, input.to - 1)) : value;
      const property = Object.hasOwn(ownProperties, key) ? ownProperties[key] : null;
      row.properties.push({ name: key, value: expression ?? null, from: child.from, to: child.to,
        editable: Boolean(definition && property && property.type !== "function" && expression !== undefined), definition: property ?? null });
    }
    const duplicate = new Set(row.properties.map(property => property.name)).size !== row.properties.length;
    row.locked ||= spread || duplicate;
    row.reason = spread ? "Spread properties are preserved; edit this element in Code." : duplicate ? "Duplicate properties are preserved; resolve them in Code." : !definition ? "Custom components and fragments are preserved; edit them in Code." : "";
    if (row.locked) row.properties.forEach(property => { property.editable = false; });
    model.nodes.push(row);
    const inner = paired ? parts.slice(1, -1) : [];
    const isComment = child => child.name === "JSXEscape" && comments.has(child.from);
    const content = inner.filter(child => !isComment(child));
    // A comment directly above a layer, with no empty line between, belongs to it.
    let lead = null;
    for (const child of inner) {
      if (isComment(child)) { lead ??= child.from; continue; }
      const raw = slice(source, child);
      if (child.name === "JSXText" && blank(raw)) { if (lead !== null && raw.split("\n").length > 2) lead = null; continue; }
      if (child.name === "JSXElement") { const layer = element(child, row.id, depth + 1); layer.outerFrom = lead ?? layer.from; row.children.push(layer.id); }
      lead = null;
    }
    row.structure = !row.locked && paired && containers.has(component) && content.every(child => child.name === "JSXElement" || (child.name === "JSXText" && !slice(source, child).trim())) && row.children.every(id => !model.nodes.find(child => child.id === id).locked);
    // With a comment inside a text, only the text itself is replaced by an edit.
    const commented = inner.length !== content.length;
    const written = commented ? content.filter(child => !(child.name === "JSXText" && blank(slice(source, child)))) : content;
    if (!row.locked && component === "Text" && paired && written.length === 1) {
      const child = written[0], raw = slice(source, child);
      // Text on a line of its own between the tags is the same text: JSX drops
      // the line breaks and the indentation around it.
      const alone = /[\r\n]/.test(raw) && !/[\r\n]/.test(raw.trim()) ? raw.trim() : null;
      const value = child.name === "JSXText" && alone ? textEntity(alone) : child.name === "JSXText" && !/[\r\n]/.test(raw) ? textEntity(raw) : child.name === "JSXEscape" ? literal(raw.slice(1, -1)) : undefined;
      if (typeof value === "string") {
        row.text = value; row.textEditable = true;
        const padding = child.name === "JSXText" ? [raw.length - raw.trimStart().length, raw.length - raw.trimEnd().length] : [0, 0];
        [row.textFrom, row.textTo] = commented ? [child.from + padding[0], child.to - padding[1]] : [row.contentFrom, row.contentTo];
      }
    }
    return row;
  }
  try {
    tree.iterate({ enter(node) {
      if (node.name !== "CallExpression") return;
      const parts = children(node.node);
      if (parts[0]?.name !== "VariableName" || slice(source, parts[0]) !== "$render" || parts[1]?.name !== "ArgList") return;
      // A comma after the element and comments beside it are not arguments.
      const args = children(parts[1]).filter(child => !["(", ")", ",", "LineComment", "BlockComment"].includes(child.name));
      if (args.length === 1 && args[0].name === "JSXElement") { model.roots.push(element(args[0], null, 0).id); return false; }
    } });
  } catch (error) { return { ...model, nodes: [], roots: [], issue: error.message }; }
  if (!model.roots.length) model.issue = "Layout needs a direct $render(<VStack>…</VStack>) or another native JSX element. Variables, loops and functions stay editable in Code.";
  return model;
}

export function visualPropertyDefinitions(node) {
  if (!node?.component || node.locked) return {};
  return { ...scriptWidgetAPI.globalProperties, ...(scriptWidgetAPI.components[node.component]?.properties ?? {}) };
}

// Where a layer (with the comment above it) goes in a container, and how it is
// written there. In code that has one layer a line, the new layer gets a line of
// its own at the indentation of its new neighbours; in code written on one line
// it is put in as it is. `offset` is where the layer itself starts in `insert`.
function place(model, source, target, siblings, index, block, layerAt, oldIndent) {
  const row = id => model.nodes.find(node => node.id === id);
  const atEnd = index === siblings.length;
  const at = atEnd ? target.contentTo : row(siblings[index]).outerFrom;
  const start = lineStart(source, at), before = source.slice(start, at);
  if (!blank(before) || start === 0) return { change: { from: at, to: at, insert: block }, offset: layerAt };
  const lead = block.slice(0, layerAt);
  if (!atEnd) {
    return { change: { from: at, to: at, insert: `${reindent(block, oldIndent, before)}\n${before}` }, offset: reindent(lead, oldIndent, before).length };
  }
  // Before the closing tag: as deep as the other layers, or one step deeper than the tag.
  const neighbour = siblings.length ? row(siblings[0]) : null;
  const neighbourLines = neighbour ? wholeLines(source, neighbour.outerFrom, neighbour.to) : null;
  const indent = neighbourLines ? neighbourLines.indent : `${before}  `;
  return { change: { from: start, to: start, insert: `${indent}${reindent(block, oldIndent, indent)}\n` }, offset: indent.length + reindent(lead, oldIndent, indent).length };
}

export function editVisualLayout(model, source, operation) {
  if (model.source !== source || model.issue) fail("Layout changed. Select the layer again before editing.");
  const node = model.nodes.find(row => row.id === operation.id);
  if (!node || node.locked) fail("This layer is locked. Edit its source in Code.");
  let changes = [], selectedFrom = node.from;
  if (operation.type === "property") {
    const definitions = visualPropertyDefinitions(node);
    const definition = Object.hasOwn(definitions, operation.name) ? definitions[operation.name] : null;
    const property = node.properties.find(property => property.name === operation.name);
    if (!definition || definition.type === "function" || (property && !property.editable)) fail("Dynamic or unsupported properties must be edited in Code.");
    const supplied = new Set(node.properties.map(value => value.name)), component = scriptWidgetAPI.components[node.component];
    if (operation.remove) {
      if (component.requiredAny?.includes(operation.name) && !component.requiredAny.some(name => name !== operation.name && supplied.has(name))) fail("Keep at least one required component property.");
      if (Object.entries(component.properties ?? {}).some(([name, value]) => supplied.has(name) && value.requires?.includes(operation.name))) fail("Another property requires this value. Edit the dependent properties together in Code.");
    } else {
      if (definition.requires?.some(name => !supplied.has(name))) fail("Add the required related properties together in Code.");
      if (definition.conflicts?.some(name => supplied.has(name)) || Object.entries(component.properties ?? {}).some(([name, value]) => name !== operation.name && supplied.has(name) && value.conflicts?.includes(operation.name))) fail("This property conflicts with another component property.");
    }
    if (operation.remove) {
      if (!property || definition.required) fail("This property cannot be removed.");
      changes = [{ from: property.from, to: property.to, insert: "" }];
    } else {
      const value = operation.value;
      if (!["string", "number", "boolean"].includes(typeof value) || (typeof value === "number" && !Number.isFinite(value)) || (typeof value === "string" && value.length > 8192)) fail("Use a bounded string, finite number or Boolean.");
      if (definition.values && !definition.values.includes(value)) fail("Choose one of the supported property values.");
      if (definition.type === "boolean" && typeof value !== "boolean") fail("This property needs true or false.");
      if (definition.type === "number" && !(typeof value === "number" || (typeof value === "string" && value.trim() && Number.isFinite(Number(value))))) fail("This property needs a number.");
      if (typeof value === "boolean" && definition.type !== "boolean") fail("This property does not accept a Boolean.");
      if (typeof value === "number" && !definition.type.includes("number")) fail("This property needs a string value.");
      if (operation.name === "opacity" && !(Number(value) >= 0 && Number(value) <= 1)) fail("Opacity must be between zero and one.");
      const insert = `${operation.name}={${JSON.stringify(value)}}`;
      changes = property ? [{ from: property.from, to: property.to, insert }] : [{ from: node.insertAt, to: node.insertAt, insert: ` ${insert}` }];
    }
  } else if (operation.type === "text") {
    if (!node.textEditable || typeof operation.value !== "string" || operation.value.length > 8192) fail("Dynamic text is preserved. Edit it in Code.");
    changes = [{ from: node.textFrom, to: node.textTo, insert: `{${JSON.stringify(operation.value)}}` }];
  } else if (operation.type === "move" || operation.type === "remove") {
    const parent = model.nodes.find(row => row.id === node.parentID);
    if (!parent?.structure) fail("Only literal children of a supported stack/grid can be moved or removed.");
    // A layer goes with the comment above it, and with its lines when it has them to itself.
    const lines = wholeLines(source, node.outerFrom, node.to);
    const removal = lines ? { from: lines.start, to: lines.end, insert: "" } : { from: node.outerFrom, to: node.to, insert: "" };
    if (operation.type === "remove") changes = [removal];
    else {
      const target = model.nodes.find(row => row.id === operation.parentID);
      if (!target?.structure || (target.from >= node.from && target.to <= node.to)) fail("Choose a supported container outside this layer.");
      const rootOf = row => { while (row.parentID !== null) row = model.nodes.find(parent => parent.id === row.parentID); return row.id; };
      if (rootOf(node) !== rootOf(target)) fail("Layers cannot move between render branches or JavaScript scopes.");
      const siblings = target.children.filter(id => id !== node.id), index = operation.index;
      if (!Number.isInteger(index) || index < 0 || index > siblings.length) fail("Invalid layer position.");
      if (target.id === parent.id && target.children.indexOf(node.id) === index) return { changes: [], selectedFrom };
      const placed = place(model, source, target, siblings, index, source.slice(node.outerFrom, node.to), node.from - node.outerFrom, lines ? lines.indent : null);
      changes = [removal, placed.change];
      selectedFrom = placed.change.from - (placed.change.from >= removal.to ? removal.to - removal.from : 0) + placed.offset;
    }
  } else if (operation.type === "add") {
    if (!node.structure) fail("Choose a supported container with literal JSX children.");
    const palette = { text: '<text font="headline">New text</text>', spacer: "<spacer/>", stack: '<vstack spacing="8"></vstack>', icon: '<icon systemName="star.fill" size="20"/>' };
    if (!Object.hasOwn(palette, operation.kind)) fail("Unsupported new layer.");
    const placed = place(model, source, node, node.children, node.children.length, palette[operation.kind], 0, null);
    changes = [placed.change]; selectedFrom = placed.change.from + placed.offset;
  } else fail("Unsupported layout operation.");
  changes.sort((a, b) => a.from - b.from);
  let next = source;
  for (const change of [...changes].reverse()) next = next.slice(0, change.from) + change.insert + next.slice(change.to);
  const parsed = parseVisualLayout(next);
  if (parsed.issue) fail("This edit would leave the supported layout. Your source was not changed.");
  return { changes, selectedFrom };
}
