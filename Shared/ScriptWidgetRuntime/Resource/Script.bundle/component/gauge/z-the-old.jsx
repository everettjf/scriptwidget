//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component gauge
// The older gauge, drawn by ScriptWidget itself: a dial with a needle and colored
// sections. Leave type out, or set type="original", to get it.
//

// The colored parts of the dial, in order. The four values add up to 1.
let gaugeSections = [
  { color: "yellow", value: 0.1 },
  { color: "blue", value: 0.2 },
  { color: "orange", value: 0.3 },
  { color: "green", value: 0.4 },
];

// $json(gaugeSections) is short for JSON.stringify: the prop takes JSON text.
$render(
  <vstack frame="max">
    <gauge
      // type="original" // default to original internal, <= iOS15
      angle="260"
      value="0.6"
      thickness="10"
      needleColor="black"
      label="60%"
      labelFont="caption"
      labelColor="red"
      title="Battery"
      titleFont="caption"
      titleColor="green"
      sections={$json(gaugeSections)}
    ></gauge>
  </vstack>,
);
