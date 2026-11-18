//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Animation Clock with more parameters
// $animation(...) turns a description object into a value for the animation prop.
// Try another interval or time zone.
//

// type "clock" keeps turning the view. anchor is the point it turns around.
// interval is in seconds: the view makes half a turn in that time, so here one full
// turn takes 60 seconds.
let animationDefinition = {
  type: "clock",
  timezone: "current", // "America/New_York" , "America/Los_Angeles" ,  "Asia/Shanghai"
  anchor: "center",
  interval: 30,
};

// The animation is on the stack, so the four circles turn together.
$render(
  <vstack frame="max" animation={$animation(animationDefinition)}>
    <circle frame="30,30" color="green"></circle>
    <circle frame="30,30" color="pink"></circle>
    <circle frame="30,30" color="gray"></circle>
    <circle frame="90,90" color="orange"></circle>
  </vstack>,
);
