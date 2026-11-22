// ScriptWidget · https://atomsprout.com/scriptwidget
// Aquarium: sea life laid out by hand in rows of emoji, with a few fish and bubbles that swim.
// Shows how to move elements with $animation.
// Try moving a creature by adding or removing spaces in its row, or changing a `distance`.
//
// $animation describes a motion to give to an element's `animation` property. A "swing"
// slides the element back and forth by up to `distance` points; a full cycle takes twice
// `duration` (in seconds).
const fishHorizontal = $animation({
  type: "swing",
  duration: 20,
  direction: "horizontal",
  distance: 100,
});
const fishVertical = $animation({
  type: "swing",
  duration: 30,
  direction: "vertical",
  distance: 70,
});
const bubbleVertical = $animation({
  type: "swing",
  duration: 15,
  direction: "vertical",
  distance: 50,
});
// $gradient builds a color gradient that can be used as a background.
const water = $gradient({
  type: "linear",
  colors: ["#013A63", "#1E81B0", "#E0FBFC"],
  startPoint: "top",
  endPoint: "bottom",
});
// The size being drawn.
const family = $getenv("widget-size");
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
  // Home Screen sizes: each row starts at the left, and the spaces inside the text place the
  // creatures. The texts are written as strings in braces so their spaces are kept as typed.
  $render(
    <vstack background={water} frame="max" alignment="top">
      <hstack alignment="leading">
        <text font="body">{"  🛟"}</text>
        <spacer />
      </hstack>
      <hstack alignment="leading">
        <text font="body">{"  🪼        🐟    🐠         🫧"}</text>
        <text font="body" animation={fishVertical}>
          🐠
        </text>
        <text font="body">{"         🫧"}</text>
        <spacer />
      </hstack>
      <hstack alignment="leading">
        <text font="body">{"  🫧"}</text>
        <text font="body">{"       "}</text>
        <text font="body" animation={bubbleVertical}>
          🫧
        </text>
        <text font="body" animation={fishHorizontal}>
          🐡🐡
        </text>
        <spacer />
      </hstack>
      <hstack alignment="leading">
        <text font="body">{"  🪼    🫧    🐬       🐬"}</text>
        <spacer />
      </hstack>
      <hstack alignment="leading">
        <text font="body">{"  🪼   🫧    🦐          🫧🫧"}</text>
        <spacer />
      </hstack>
      <hstack alignment="leading">
        <text font="body">{"  🍀 🪸🌿🪸⚓️🗿🐙🐙  🌿🌿 🌿🪸🪸"}</text>
        <spacer />
      </hstack>
    </vstack>,
  );
}
