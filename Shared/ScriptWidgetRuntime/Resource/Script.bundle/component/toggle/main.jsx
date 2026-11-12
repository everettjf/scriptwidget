// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for component capsule
// 


const onToggleClick = () => {
  console.log("toggle tapped");
}
const widget_size = $getenv("widget-size");

const value = Math.random() >= 0.5;

$render(
  <vstack frame="max">
    <toggle on={value} onClick="onToggleClick">
      <image systemName="mosaic.fill" />
      <text>{widget_size}</text>
    </toggle>
  </vstack>
);
