//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// component: line
// A line with a length and a thickness. axis="vertical" makes it stand upright.
//

// frame="max" makes the stack fill the widget; spacing is the gap between its children.
$render(
  <vstack frame="max" spacing="8">
    <line length="120" thickness="2" color="#94a3b8" />
    <hstack spacing="8">
      <line axis="vertical" length="24" thickness="2" color="#f59e0b" />
      <text font="caption">Vertical line</text>
    </hstack>
  </vstack>,
);
