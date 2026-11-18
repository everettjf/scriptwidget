//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component gauge
// A system gauge (type="system"). value is how full it is, from 0 to 1.
// Try style="linear".
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
