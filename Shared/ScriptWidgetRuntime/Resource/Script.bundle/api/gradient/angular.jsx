//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for api $gradient
// $gradient(...) turns a description object into a value for the background prop.
// Try other colors, or more of them.
//

// An angular gradient sweeps through the colors around the center, like a color wheel.
let angularGradient = {
  type: "angular",
  colors: ["green", "blue", "black", "green", "blue", "black", "green"],
  center: "center",
};

// frame="max" makes the stack, and with it the gradient, fill the whole widget.
$render(
  <vstack background={$gradient(angularGradient)} frame="max">
    <text font="title">AngularGradient</text>
  </vstack>,
);
