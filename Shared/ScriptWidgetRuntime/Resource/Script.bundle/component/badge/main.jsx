//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// component: badge
// A badge is a short text on a colored background. Try other texts and colors.
//

// frame="max" makes the stack fill the widget; spacing is the gap between its children.
$render(
  <vstack frame="max" spacing="8">
    <badge text="PRO" background="#22c55e" color="#ffffff" />
    <badge text="BETA" background="#0f172a" color="#e2e8f0" />
  </vstack>,
);
