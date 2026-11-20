import { scriptWidgetAPI } from "./scriptWidgetAPI.js";
import { editorAPI } from "./hostAPI.js";

export { scriptWidgetAPI };

function componentSnippet(name, component) {
  const required = Object.entries(component.properties ?? {})
    .filter(([, property]) => property.required)
    .map(([property, definition]) => `${property}=${definition.type.includes("number") || definition.type === "boolean" ? `{\${}}` : `"\${}"`}`)
    .join(" ");
  const attributes = required ? ` ${required}` : "";
  return component.children ? `<${name}${attributes}>\n  \${}\n</${name}>` : `<${name}${attributes} />`;
}

function componentOptions(components) {
  return Object.entries(components).map(([label, component]) => ({
    label,
    type: "class",
    detail: `ScriptWidget · ${Object.keys(component.properties ?? {}).length} properties`,
    info: component.documentation,
    template: componentSnippet(label, component),
  }));
}

// An option's `template` is a CodeMirror snippet: "${}" marks where the
// cursor goes. This module imports no package, because Web Studio bundles it
// from another folder; the editor hands over CodeMirror's `snippet` function
// with useSnippets. Without it the marks are simply left out. After a typed
// "<" the completion starts behind it, so the template's own "<" is left out
// there.
let makeSnippet = null;
export function useSnippets(snippet) {
  makeSnippet = typeof snippet === "function" ? snippet : null;
}

function insertable(options, afterOpeningBracket = false) {
  return options.map((option) => {
    if (typeof option.template !== "string") return option;
    const template = afterOpeningBracket && option.template.startsWith("<") ? option.template.slice(1) : option.template;
    return { ...option, apply: makeSnippet ? makeSnippet(template) : template.replaceAll("${}", "") };
  });
}

export const scriptWidgetCompletionOptions = componentOptions(scriptWidgetAPI.components);

// The tags to offer: the constant above, with the host's own tags after it
// when the host supplies some (see hostAPI.js).
let hostOptionsFor = null;
let hostOptions = scriptWidgetCompletionOptions;
function tagOptions() {
  const { api, extended } = editorAPI();
  if (!extended) return scriptWidgetCompletionOptions;
  if (hostOptionsFor !== api) {
    hostOptionsFor = api;
    hostOptions = componentOptions(api.components);
  }
  return hostOptions;
}

function activeOpeningTag(text) {
  const match = text.match(/<([A-Za-z][\w]*)\b([^<>]*)$/);
  if (!match || match[2].includes(">")) return null;
  return { name: match[1], attributes: match[2] };
}

function propertyOptions(componentName, usedNames) {
  const api = editorAPI().api;
  const component = api.components[componentName];
  if (!component) return [];
  return Object.entries({ ...api.globalProperties, ...(component.properties ?? {}) })
    .filter(([name]) => !usedNames.has(name))
    .map(([label, property]) => ({
      label,
      type: "property",
      detail: property.required ? `${property.type} · required` : property.type,
      info: property.deprecated ? `Deprecated: ${property.deprecated}` : property.documentation,
      template: `${label}=${property.type.includes("number") || property.type === "boolean" ? `{\${}}` : `"\${}"`}`,
    }));
}

function enumValueOptions(text) {
  const match = text.match(/<([A-Za-z][\w]*)\b[^<>]*\b([A-Za-z][\w]*)\s*=\s*["']([^"']*)$/);
  if (!match) return null;
  const { api, colors } = editorAPI();
  const definition = api.components[match[1]]?.properties?.[match[2]] ?? api.globalProperties[match[2]];
  // Color names the host adds, such as Android's "material.primary". Only a
  // whole value is completed, not a part of "name,opacity" or of a gradient.
  if (definition?.type === "color" && colors.length && /^[\w.]*$/.test(match[3])) {
    return { typed: match[3], values: colors, type: "constant", validFor: /^[\w.]*$/ };
  }
  if (!definition?.values) return null;
  return { typed: match[3], values: definition.values, type: "enum", validFor: /^[\w-]*$/ };
}

export function scriptWidgetCompletions(context) {
  const before = context.state.doc.sliceString(Math.max(0, context.pos - 1200), context.pos);
  const enumContext = enumValueOptions(before);
  if (enumContext) {
    return {
      from: context.pos - enumContext.typed.length,
      options: enumContext.values.map((label) => ({ label, type: enumContext.type })),
      validFor: enumContext.validFor,
    };
  }

  const tag = context.matchBefore(/<[A-Za-z]*$/);
  if (tag) {
    return {
      from: tag.from + 1,
      options: insertable(tagOptions(), true),
      validFor: /^[A-Za-z]*$/,
    };
  }

  const openingTag = activeOpeningTag(before);
  if (openingTag && /(?:\s|^)\w*$/.test(openingTag.attributes)) {
    const word = context.matchBefore(/[A-Za-z][\w]*$/);
    const usedNames = new Set([...openingTag.attributes.matchAll(/\b([A-Za-z][\w]*)\s*=/g)].map((match) => match[1]));
    return {
      from: word?.from ?? context.pos,
      options: insertable(propertyOptions(openingTag.name, usedNames)),
      validFor: /^[A-Za-z][\w]*$/,
    };
  }

  const apiMethod = context.matchBefore(/\$[A-Za-z]+\.[A-Za-z]*$/);
  if (apiMethod) {
    const prefix = apiMethod.text.slice(0, apiMethod.text.indexOf(".") + 1);
    const definitions = Object.entries(scriptWidgetAPI.functions).filter(([name]) => name.startsWith(prefix));
    if (!definitions.length) return null;
    return {
      from: apiMethod.from + prefix.length,
      options: definitions
        .map(([name, definition]) => ({
          label: name.slice(prefix.length),
          type: "function",
          detail: definition.returns,
          info: definition.documentation,
        })),
      validFor: /^[A-Za-z]*$/,
    };
  }

  if (!context.explicit) return null;
  return {
    from: context.pos,
    options: insertable(tagOptions()),
    validFor: /^[A-Za-z]*$/,
  };
}
