//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component attribute frame
// frame="50,max": 50 points wide and as high as the stack lets it be.
//

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max">
    <rect frame="50,max" color="green"></rect>
    <rect frame="50,30" color="blue" corner="5"></rect>
  </vstack>,
);
