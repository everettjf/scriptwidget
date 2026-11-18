//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component $getenv
// $getenv(name) reads a value that the system hands to the script.
// Try: add the widget in each size, and type a parameter when you configure it.
//

/*
 widget-size
 - large
 - medium
 - small
*/
const widget_size = $getenv("widget-size");

/*
 parameter config in system widget config panel
*/
const widget_param = $getenv("widget-param");

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max">
    <text font="title">Widget Size : {widget_size}</text>
    <text font="caption">Widget Parameter : {widget_param}</text>
  </vstack>,
);
