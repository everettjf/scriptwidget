const components = [
  ["Text", "Display styled text", '<Text text="${text}" />'],
  ["Image", "Display an image or SF Symbol", '<Image systemName="${star.fill}" />'],
  ["VStack", "Arrange children vertically", "<VStack>\n  ${}\n</VStack>"],
  ["HStack", "Arrange children horizontally", "<HStack>\n  ${}\n</HStack>"],
  ["ZStack", "Overlay children", "<ZStack>\n  ${}\n</ZStack>"],
  ["Spacer", "Flexible space between views", "<Spacer />"],
  ["Divider", "Visual separator", "<Divider />"],
  ["Link", "Open a URL when tapped", '<Link url="${https://example.com}">\n  ${}\n</Link>'],
  ["Gauge", "Display a value in a bounded range", '<Gauge value={${0.5}} />'],
  ["ProgressView", "Display progress", '<ProgressView value={${0.5}} />'],
  ["Canvas", "Draw custom graphics", "<Canvas>\n  ${}\n</Canvas>"],
];

export const scriptWidgetCompletionOptions = components.map(([label, info, apply]) => ({
  label,
  type: "class",
  detail: "ScriptWidget",
  info,
  apply,
}));

export function scriptWidgetCompletions(context) {
  const tag = context.matchBefore(/<[A-Za-z]*$/);
  if (!tag && !context.explicit) return null;

  return {
    from: tag ? tag.from + 1 : context.pos,
    options: scriptWidgetCompletionOptions,
    validFor: /^[A-Za-z]*$/,
  };
}
