//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// component: icon
// An icon is an SF Symbol, chosen with systemName, with a size and a color.
//

// frame="max" makes the stack fill the widget; spacing is the gap between its children.
$render(
  <hstack frame="max" spacing="12">
    <icon systemName="bolt.fill" size="24" color="#fbbf24" />
    <icon systemName="moon.stars.fill" size="24" color="#6366f1" />
  </hstack>,
);
