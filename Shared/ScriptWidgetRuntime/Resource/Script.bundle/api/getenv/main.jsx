// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for component $getenv
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

$render(
  <vstack frame="max">
    <text font="title">Widget Size : {widget_size}</text>
    <text font="caption">Widget Parameter : {widget_param}</text>
  </vstack>
);
