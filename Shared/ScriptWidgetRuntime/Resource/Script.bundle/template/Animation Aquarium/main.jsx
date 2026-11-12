// ScriptWidget · https://atomsprout.com/scriptwidget
// Aquarium: one creature per bounded cell, with family-specific compositions.
// WidgetKit may freeze motion. The scene remains complete at its resting pose.
const family = $getenv("widget-size");
const compact = family === "small";
const roomy = ["large", "extraLarge", "extraLargePortrait"].includes(family);
const cell = roomy ? 36 : 28;
const font = roomy ? "26" : "20";
const fishHorizontal = $animation({ type: "swing", duration: 20, direction: "horizontal", distance: compact ? 6 : 10 });
const fishVertical = $animation({ type: "swing", duration: 30, direction: "vertical", distance: 5 });
const bubbleVertical = $animation({ type: "swing", duration: 15, direction: "vertical", distance: 6 });
const water = $gradient({
  type: "linear",
  colors: ["#013A63", "#1E81B0", "#E0FBFC"],
  startPoint: "top",
  endPoint: "bottom",
});
const motion = symbol => symbol === "🐡" ? fishHorizontal : symbol === "🐠" ? fishVertical : symbol === "🫧" ? bubbleVertical : undefined;
const Row = ({ symbols }) => (
  <hstack spacing="0" frame={`max,${cell}`}>
    {symbols.map(symbol => (
      <hstack spacing="0" frame="max">
        <text font={font} frame={`${cell},${cell}`} animation={motion(symbol)}>{symbol}</text>
      </hstack>
    ))}
  </hstack>
);
if (family === "accessoryInline") {
  $render(<text>Aquarium 🐠</text>);
} else if (family === "accessoryCircular") {
  $render(<text font="28">🐠</text>);
} else if (family === "accessoryRectangular") {
  $render(<hstack spacing="8"><text font="24">🐠</text><text font="headline">Aquarium</text><text font="20">🪸</text></hstack>);
} else {
  $render(
    <vstack background={water} frame="max" spacing="0" padding="10">
      <Row symbols={compact ? ["🛟", "🫧", "🪼"] : ["🛟", "🫧", "🪼", "🐟", "🫧"]} />
      <spacer />
      <Row symbols={compact ? ["🐟", "🐠", "🫧"] : ["🪼", "🐟", "🐠", "🫧", "🐬"]} />
      <spacer />
      <Row symbols={compact ? ["🫧", "🐡", "🦐"] : ["🫧", "🦐", "🐡", "🐟", "🫧"]} />
      {roomy && <spacer />}
      {roomy && <Row symbols={["🪼", "🫧", "🐬", "🦐", "🫧"]} />}
      <spacer />
      <Row symbols={compact ? ["🪸", "🌿", "🐙", "🌿"] : ["🍀", "🪸", "🌿", "⚓️", "🐙", "🌿", "🪸"]} />
    </vstack>
  );
}
