// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for api $gradient
// 

let angularGradient = {
  type: "angular",
  colors: ["green", "blue", "black", "green", "blue", "black", "green"],
  center: "center",
};

$render(
  <vstack background={$gradient(angularGradient)} frame="max">
    <text font="title">AngularGradient</text>
  </vstack>
);
