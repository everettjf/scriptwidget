//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component gauge
// min and max are the labels at the two ends of the gauge. They are text only: how
// full the gauge is still comes from value, from 0 to 1.
//

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max">
    <gauge
      type="system"
      value="0.6"
      text="hello" // not display
      current="60"
      min="0"
      max="100"
      style="circular" // default
    ></gauge>
  </vstack>,
);
