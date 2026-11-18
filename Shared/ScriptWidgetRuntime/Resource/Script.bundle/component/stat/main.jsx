//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// component: stat
// A stat shows a title, a value and a subtitle. color is the color of the value.
//

// frame="max" makes the stack fill the widget; spacing is the gap between its children.
$render(
  <hstack frame="max" spacing="16">
    <stat title="Downloads" value="12.4k" subtitle="Today" color="#0f172a" />
    <stat title="Streak" value="18" subtitle="Days" color="#22c55e" />
  </hstack>,
);
