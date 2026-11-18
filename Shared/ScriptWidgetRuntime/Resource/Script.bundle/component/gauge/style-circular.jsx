//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component gauge
// style="circular" draws the gauge as a ring. It is the default.
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
