//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// component: chip
// A chip is a small rounded label. Try other texts and colors.
//

// frame="max" makes the stack fill the widget; spacing is the gap between its children.
$render(
  <hstack frame="max" spacing="8">
    <chip text="Today" />
    <chip text="Focus" borderColor="#38bdf8" color="#0f172a" />
  </hstack>,
);
