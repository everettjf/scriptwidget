//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component rect
// A rectangle with a frame ("width,height" in points) and a color. corner rounds it.
//

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max">
    <rect frame="50,30" color="blue"></rect>
    <rect frame="50,30" color="blue" corner="5"></rect>
  </vstack>,
);
