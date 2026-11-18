//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for api $gradient
// $gradient(...) turns a description object into a value for the background prop.
// Try other colors, or more of them.
//

// A radial gradient spreads out in circles from the center, between the two radii.
let radialGradient = {
  type: "radial",
  colors: ["orange", "red", "white"],
  center: "center",
  startRadius: 100,
  endRadius: 470,
};

// frame="max" makes the stack, and with it the gradient, fill the whole widget.
$render(
  <vstack background={$gradient(radialGradient)} frame="max">
    <text font="title">RadialGradient</text>
  </vstack>,
);
