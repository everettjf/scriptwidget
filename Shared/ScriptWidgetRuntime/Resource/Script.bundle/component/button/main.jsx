//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component button
// Two buttons in a widget. Buttons need iOS 17 or macOS 14; on older systems they are
// shown but cannot be tapped. Try changing what onButtonClick does.
//

// Runs when the first button is tapped. onClick takes the name of this function as text.
const onButtonClick = () => {
  console.log("button tapped");
};
// The size of this widget, for example "small". It is shown as the label of the button.
const widget_size = $getenv("widget-size");

$render(
  <vstack frame="max">
    {/* The children of a button are its label. */}
    <button onClick="onButtonClick">
      <image systemName="mosaic.fill" />
      <text>{widget_size}</text>
    </button>
    {/* action="reload" refreshes the widget. */}
    <button action="reload">
      <text>Refresh Widget</text>
    </button>
  </vstack>,
);
