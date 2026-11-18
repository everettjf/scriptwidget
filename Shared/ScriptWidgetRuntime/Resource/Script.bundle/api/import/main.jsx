// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// import other js/jsx files
// $import(name) runs another file of this package in the same global scope, so this
// file can use what that file defines. Try adding a function to define.js.
//

// util.jsx defines textItems; define.js defines sum().
$import("util.jsx");
$import("define.js");

$render(
  <vstack>
    <text font="title">test</text>
    {/* An array of elements in braces is drawn as that many children. */}
    {textItems}
    <text font="title">{sum(1, 2)}</text>
  </vstack>,
);
