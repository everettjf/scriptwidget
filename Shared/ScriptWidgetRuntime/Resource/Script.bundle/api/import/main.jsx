// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// import other js/jsx files
//

$import("util.jsx");
$import("define.js");

$render(
  <vstack>
    <text font="title">test</text>
    {textItems}
    <text font="title">{sum(1, 2)}</text>
  </vstack>
);
