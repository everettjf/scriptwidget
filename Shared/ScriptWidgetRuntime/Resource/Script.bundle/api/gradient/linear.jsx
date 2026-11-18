//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for api $gradient
// $gradient(...) turns a description object into a value for the background prop.
// Try other colors, or more of them.
//

// A linear gradient runs in a straight line from startPoint to endPoint.
let linearGradient = {
  type: "linear",
  colors: ["blue", "white", "pink"],
  startPoint: "topLeading",
  endPoint: "bottomTrailing",
};

// frame="max" makes the stack, and with it the gradient, fill the whole widget.
$render(
  <vstack background={$gradient(linearGradient)} frame="max">
    <text font="title">LinearGradient</text>
  </vstack>,
);
