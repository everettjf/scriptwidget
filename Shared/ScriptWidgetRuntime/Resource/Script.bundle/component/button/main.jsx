// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for component button
// 


const onButtonClick = () => {
  console.log("button tapped");
};
const widget_size = $getenv("widget-size");

$render(
  <vstack frame="max">
    <button onClick="onButtonClick">
      <image systemName="mosaic.fill" />
      <text>{widget_size}</text>
    </button>
    <button action="reload">
      <text>Refresh Widget</text>
    </button>
  </vstack>
);
