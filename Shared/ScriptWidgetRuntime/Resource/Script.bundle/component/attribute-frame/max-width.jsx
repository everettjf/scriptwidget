//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component attribute frame
// frame="max,30": as wide as the stack lets it be and 30 points high.
//

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max">
    <rect frame="max,30" color="green"></rect>
    <rect frame="50,30" color="blue" corner="5"></rect>
  </vstack>,
);
