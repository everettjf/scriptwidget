//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component gauge
// style="automatic" lets the system choose the look of the gauge.
//

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max">
    <gauge type="system" value="0.6" text="hello" style="automatic"></gauge>
  </vstack>,
);
