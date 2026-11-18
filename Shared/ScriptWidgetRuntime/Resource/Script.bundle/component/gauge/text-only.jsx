//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component gauge
// A gauge with only text set: no current, min or max. value is from 0 to 1.
//

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max">
    <gauge
      type="system"
      value="0.6"
      text="hello"
      style="circular" // default
    ></gauge>
  </vstack>,
);
