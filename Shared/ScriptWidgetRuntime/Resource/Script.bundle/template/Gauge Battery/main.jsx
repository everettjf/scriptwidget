//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Battery Gauge
//
// Shows the battery charge on a round gauge.
// Try changing the colors of the sections, the angle or the thickness.

// $device.battery().level is the charge from 0 to 1. Make it a whole percentage;
// toFixed(0) rounds and returns text, such as "87".
var percent = $device.battery().level * 100;
percent = percent.toFixed(0);

// The colored parts of the gauge, in order. `value` is the share of the scale that a
// part covers, so the values add up to 1.
let gaugeSections = [
  { color: "yellow", value: 0.1 },
  { color: "blue", value: 0.2 },
  { color: "orange", value: 0.3 },
  { color: "green", value: 0.4 },
];

// $render draws the widget. frame="max" lets the stack fill the whole widget.
// `value` is the needle position from 0 to 1. `sections` takes JSON text, which
// $json(…) makes from the array.
$render(
  <vstack frame="max">
    <gauge
      angle="260"
      value={percent / 100}
      thickness="10"
      label={percent + "%"}
      labelFont="caption"
      title="BATTERY"
      titleFont="caption"
      sections={$json(gaugeSections)}
    ></gauge>
  </vstack>,
);
