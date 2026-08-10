import { scriptWidgetAPI } from "./scriptWidgetAPI.js";

export { scriptWidgetAPI };

function componentSnippet(name, component) {
  const required = Object.entries(component.properties ?? {})
    .filter(([, property]) => property.required)
    .map(([property, definition]) => `${property}=${definition.type.includes("number") || definition.type === "boolean" ? `{\${}}` : `"\${}"`}`)
    .join(" ");
  const attributes = required ? ` ${required}` : "";
  return component.children ? `<${name}${attributes}>\n  \${}\n</${name}>` : `<${name}${attributes} />`;
}

export const scriptWidgetCompletionOptions = Object.entries(scriptWidgetAPI.components).map(([label, component]) => ({
  label,
  type: "class",
  detail: `ScriptWidget · ${Object.keys(component.properties ?? {}).length} properties`,
  info: component.documentation,
  apply: componentSnippet(label, component),
}));

function activeOpeningTag(text) {
  const match = text.match(/<([A-Za-z][\w]*)\b([^<>]*)$/);
  if (!match || match[2].includes(">")) return null;
  return { name: match[1], attributes: match[2] };
}

function propertyOptions(componentName, usedNames) {
  const component = scriptWidgetAPI.components[componentName];
  if (!component) return [];
  return Object.entries({ ...scriptWidgetAPI.globalProperties, ...(component.properties ?? {}) })
    .filter(([name]) => !usedNames.has(name))
    .map(([label, property]) => ({
      label,
      type: "property",
      detail: property.required ? `${property.type} · required` : property.type,
      info: property.deprecated ? `Deprecated: ${property.deprecated}` : property.documentation,
      apply: `${label}=${property.type.includes("number") || property.type === "boolean" ? `{\${}}` : `"\${}"`}`,
    }));
}

function enumValueOptions(text) {
  const match = text.match(/<([A-Za-z][\w]*)\b[^<>]*\b([A-Za-z][\w]*)\s*=\s*["']([^"']*)$/);
  if (!match) return null;
  const definition = scriptWidgetAPI.components[match[1]]?.properties?.[match[2]] ?? scriptWidgetAPI.globalProperties[match[2]];
  if (!definition?.values) return null;
  return { typed: match[3], values: definition.values };
}

export function scriptWidgetCompletions(context) {
  const before = context.state.doc.sliceString(Math.max(0, context.pos - 1200), context.pos);
  const enumContext = enumValueOptions(before);
  if (enumContext) {
    return {
      from: context.pos - enumContext.typed.length,
      options: enumContext.values.map((label) => ({ label, type: "enum" })),
      validFor: /^[\w-]*$/,
    };
  }

  const tag = context.matchBefore(/<[A-Za-z]*$/);
  if (tag) {
    return {
      from: tag.from + 1,
      options: scriptWidgetCompletionOptions,
      validFor: /^[A-Za-z]*$/,
    };
  }

  const openingTag = activeOpeningTag(before);
  if (openingTag && /(?:\s|^)\w*$/.test(openingTag.attributes)) {
    const word = context.matchBefore(/[A-Za-z][\w]*$/);
    const usedNames = new Set([...openingTag.attributes.matchAll(/\b([A-Za-z][\w]*)\s*=/g)].map((match) => match[1]));
    return {
      from: word?.from ?? context.pos,
      options: propertyOptions(openingTag.name, usedNames),
      validFor: /^[A-Za-z][\w]*$/,
    };
  }

  if (!context.explicit) return null;
  return {
    from: context.pos,
    options: scriptWidgetCompletionOptions,
    validFor: /^[A-Za-z]*$/,
  };
}
