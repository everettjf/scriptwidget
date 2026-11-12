// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for api $gradient
// 

let radialGradient = {
  type: "radial",
  colors: ["orange", "red", "white"],
  center: "center",
  startRadius: 100,
  endRadius: 470,
};

$render(
  <vstack background={$gradient(radialGradient)} frame="max">
    <text font="title">RadialGradient</text>
  </vstack>
);
