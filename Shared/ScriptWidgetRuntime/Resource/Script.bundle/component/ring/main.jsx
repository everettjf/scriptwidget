//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// component: ring
// A ring filled up to value, from 0 to 1. trackColor is the color of the unfilled part.
// frame="72" makes it 72 by 72 points. Try another value or thickness.
//

$render(
  <vstack frame="max" padding="12">
    <ring value="0.68" thickness="10" color="#22c55e" trackColor="#e2e8f0" frame="72" />
  </vstack>,
);
