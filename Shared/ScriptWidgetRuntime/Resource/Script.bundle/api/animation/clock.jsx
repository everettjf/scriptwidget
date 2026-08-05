//
// ScriptWidget
// https://xnu.app/scriptwidget
//
// Animation Clock with more parameters
//


let animationDefinition = {
  type: "clock",
  timezone: "current", // "America/New_York" , "America/Los_Angeles" ,  "Asia/Shanghai"
  anchor: "center",
  interval: 30,
}


$render(
  <vstack frame="max" animation={$animation(animationDefinition)}>
    <circle frame="30,30" color="green"></circle>
    <circle frame="30,30" color="pink"></circle>
    <circle frame="30,30" color="gray"></circle>
    <circle frame="90,90" color="orange"></circle>
  </vstack>
);
