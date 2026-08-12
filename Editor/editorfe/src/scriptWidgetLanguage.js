import { syntaxTree } from "@codemirror/language";
import { scriptWidgetAPI } from "./scriptWidgetCompletions.js";

function childNodes(node, name) {
  const children = [];
  for (let child = node.node.firstChild; child; child = child.nextSibling) {
    if (child.name === name) children.push(child);
  }
  return children;
}

function openingTags(state) {
  const tags = [];
  syntaxTree(state).iterate({
    enter(node) {
      if (node.name !== "JSXOpenTag" && node.name !== "JSXSelfClosingTag") return;
      const identifiers = childNodes(node, "JSXIdentifier");
      const nameNode = identifiers[0];
      if (!nameNode) return;
      tags.push({
        name: state.doc.sliceString(nameNode.from, nameNode.to),
        from: nameNode.from,
        to: nameNode.to,
        attributes: childNodes(node, "JSXAttribute").map((attribute) => {
          const identifier = attribute.firstChild;
          return identifier ? {
            name: state.doc.sliceString(identifier.from, identifier.to),
            from: identifier.from,
            to: identifier.to,
          } : null;
        }).filter(Boolean),
      });
    },
  });
  return tags;
}

export function scriptWidgetDiagnostics(view) {
  const diagnostics = [];
  for (const tag of openingTags(view.state)) {
    const component = scriptWidgetAPI.components[tag.name];
    if (!component) continue; // Custom components are part of the public runtime.
    const allowed = new Set([...Object.keys(scriptWidgetAPI.globalProperties), ...Object.keys(component.properties ?? {})]);
    const supplied = new Set(tag.attributes.map((attribute) => attribute.name));
    for (const attribute of tag.attributes) {
      if (!allowed.has(attribute.name)) {
        diagnostics.push({ from: attribute.from, to: attribute.to, severity: "warning", message: `“${attribute.name}” is not supported by <${tag.name}>.` });
      }
      const property = component.properties?.[attribute.name] ?? scriptWidgetAPI.globalProperties[attribute.name];
      if (property?.deprecated) {
        diagnostics.push({ from: attribute.from, to: attribute.to, severity: "warning", message: `${attribute.name} is deprecated. ${property.deprecated}` });
      }
    }
    for (const [name, property] of Object.entries(component.properties ?? {})) {
      if (property.required && !supplied.has(name)) {
        diagnostics.push({ from: tag.from, to: tag.to, severity: "error", message: `<${tag.name}> requires the “${name}” property.` });
      }
      if (supplied.has(name)) {
        for (const dependency of property.requires ?? []) {
          if (!supplied.has(dependency)) {
            diagnostics.push({ from: tag.from, to: tag.to, severity: "error", message: `<${tag.name}> “${name}” requires the “${dependency}” property.` });
          }
        }
        for (const conflict of property.conflicts ?? []) {
          if (supplied.has(conflict) && name < conflict) {
            diagnostics.push({ from: tag.from, to: tag.to, severity: "error", message: `<${tag.name}> cannot combine “${name}” with “${conflict}”.` });
          }
        }
      }
    }
    if (component.requiredAny?.length && !component.requiredAny.some((name) => supplied.has(name))) {
      diagnostics.push({
        from: tag.from,
        to: tag.to,
        severity: "error",
        message: `<${tag.name}> requires one of: ${component.requiredAny.map((name) => `“${name}”`).join(", ")}.`,
      });
    }
  }
  return diagnostics;
}

export function scriptWidgetHover(view, position) {
  const tag = openingTags(view.state).find((candidate) => position >= candidate.from && position <= candidate.to);
  if (!tag) return null;
  const component = scriptWidgetAPI.components[tag.name];
  if (!component) return null;
  return {
    pos: tag.from,
    end: tag.to,
    above: true,
    create() {
      const dom = document.createElement("div");
      dom.className = "studio-hover";
      const title = document.createElement("strong");
      title.textContent = `<${tag.name}>`;
      const detail = document.createElement("p");
      detail.textContent = component.documentation;
      dom.append(title, detail);
      return { dom };
    },
  };
}

export { openingTags };
