// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for api $gradient
// 

let linearGradient = {
  type: "linear",
  colors: ["blue", "white", "pink"],
  startPoint: "topLeading",
  endPoint: "bottomTrailing",
};

$render(
  <vstack background={$gradient(linearGradient)} frame="max">
    <text font="title">LinearGradient</text>
  </vstack>
);
