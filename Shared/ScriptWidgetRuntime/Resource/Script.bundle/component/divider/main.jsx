//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// component: divider
// A divider is a thin line between two parts. Try another thickness or color.
//

// frame="max" makes the stack fill the widget; padding keeps the content off its edges.
$render(
  <vstack frame="max" padding="12">
    <text font="caption">Section A</text>
    <divider thickness="1" color="#94a3b8" />
    <text font="caption">Section B</text>
  </vstack>,
);
