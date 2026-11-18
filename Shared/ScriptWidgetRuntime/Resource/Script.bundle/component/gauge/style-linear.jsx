//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component gauge
// style="linear" draws the gauge as a bar.
//

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max">
    <gauge type="system" value="0.6" text="hello" style="linear"></gauge>
  </vstack>,
);
