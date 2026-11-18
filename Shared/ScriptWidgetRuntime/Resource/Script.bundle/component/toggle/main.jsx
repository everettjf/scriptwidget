//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component toggle
// A switch in a widget. Toggles need iOS 17 or macOS 14; on older systems they are
// shown but cannot be tapped.
//

// Runs when the toggle is tapped. onClick takes the name of this function as text.
const onToggleClick = () => {
  console.log("toggle tapped");
};
const widget_size = $getenv("widget-size");

// A random on/off state, only for this demo: it changes with every redraw.
// A real widget would keep the state, for example in $storage.
const value = Math.random() >= 0.5;

$render(
  <vstack frame="max">
    {/* on is the state shown; the children are the label. */}
    <toggle on={value} onClick="onToggleClick">
      <image systemName="mosaic.fill" />
      <text>{widget_size}</text>
    </toggle>
  </vstack>,
);
