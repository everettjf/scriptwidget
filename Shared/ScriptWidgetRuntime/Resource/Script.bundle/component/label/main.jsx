//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// component: label
// A label is an icon and a title side by side. systemName is the name of an SF Symbol.
//

// frame="max" makes the stack fill the widget; spacing is the gap between its children.
$render(
  <vstack frame="max" spacing="8">
    <label title="Sunrise" systemName="sunrise.fill" color="#f59e0b" />
    <label title="Battery" systemName="battery.100" color="#22c55e" />
  </vstack>,
);
