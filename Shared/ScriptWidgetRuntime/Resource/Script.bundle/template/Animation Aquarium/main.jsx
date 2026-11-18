// ScriptWidget · https://atomsprout.com/scriptwidget
// Aquarium: one creature per bounded cell, with family-specific compositions.
// WidgetKit may freeze motion. The scene remains complete at its resting pose.
// Shows how to move elements with $animation and how to build rows from lists of emoji.
// Try changing the emoji in the rows at the bottom, or the `distance` of a motion.
//
// The size being drawn. `compact` and `roomy` choose smaller or larger cells and rows.
const family = $getenv("widget-size");
const compact = family === "small";
const roomy = ["large", "extraLarge", "extraLargePortrait"].includes(family);
// The side of one creature's cell, and its font size, in points.
const cell = roomy ? 36 : 28;
const font = roomy ? "26" : "20";
// $animation describes a motion to give to an element's `animation` property. A "swing"
// slides the element back and forth by up to `distance` points; a full cycle takes twice
// `duration` (in seconds).
const fishHorizontal = $animation({
  type: "swing",
  duration: 20,
  direction: "horizontal",
  distance: compact ? 6 : 10,
});
const fishVertical = $animation({
  type: "swing",
  duration: 30,
  direction: "vertical",
  distance: 5,
});
const bubbleVertical = $animation({
  type: "swing",
  duration: 15,
  direction: "vertical",
  distance: 6,
});
// $gradient builds a color gradient that can be used as a background.
const water = $gradient({
  type: "linear",
  colors: ["#013A63", "#1E81B0", "#E0FBFC"],
  startPoint: "top",
  endPoint: "bottom",
});
// Which motion each emoji gets. All others stay still.
const motion = (symbol) =>
  symbol === "🐡"
    ? fishHorizontal
    : symbol === "🐠"
      ? fishVertical
      : symbol === "🫧"
        ? bubbleVertical
        : undefined;
// One row of the scene: each emoji sits in the middle of an equal share of the width.
const Row = ({ symbols }) => (
  <hstack spacing="0" frame={`max,${cell}`}>
    {symbols.map((symbol) => (
      <hstack spacing="0" frame="max">
        <text font={font} frame={`${cell},${cell}`} animation={motion(symbol)}>
          {symbol}
        </text>
      </hstack>
    ))}
  </hstack>
);
// Lock Screen sizes (the "accessory" ones) get a small picture without motion.
if (family === "accessoryInline") {
  $render(<text>Aquarium 🐠</text>);
} else if (family === "accessoryCircular") {
  $render(<text font="28">🐠</text>);
} else if (family === "accessoryRectangular") {
  $render(
    <hstack spacing="8">
      <text font="24">🐠</text>
      <text font="headline">Aquarium</text>
      <text font="20">🪸</text>
    </hstack>,
  );
} else {
  // Home Screen sizes: rows of sea life above the seabed, with spacers between them.
  $render(
    <vstack background={water} frame="max" spacing="0" padding="10">
      <Row symbols={compact ? ["🛟", "🫧", "🪼"] : ["🛟", "🫧", "🪼", "🐟", "🫧"]} />
      <spacer />
      <Row symbols={compact ? ["🐟", "🐠", "🫧"] : ["🪼", "🐟", "🐠", "🫧", "🐬"]} />
      <spacer />
      <Row symbols={compact ? ["🫧", "🐡", "🦐"] : ["🫧", "🦐", "🐡", "🐟", "🫧"]} />
      {/* One more row, only on the large sizes. */}
      {roomy && <spacer />}
      {roomy && <Row symbols={["🪼", "🫧", "🐬", "🦐", "🫧"]} />}
      <spacer />
      <Row
        symbols={compact ? ["🪸", "🌿", "🐙", "🌿"] : ["🍀", "🪸", "🌿", "⚓️", "🐙", "🌿", "🪸"]}
      />
    </vstack>,
  );
}
