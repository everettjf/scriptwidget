//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component gauge
// current is the label for the current value. A circular gauge shows it and not text.
//

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max">
    <gauge
      type="system"
      value="0.6"
      text="hello" // not display
      current="60"
      style="circular" // default
    ></gauge>
  </vstack>,
);
