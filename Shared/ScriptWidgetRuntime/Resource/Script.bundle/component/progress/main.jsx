//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// component: progress
// A progress bar and a round one. value is how far it is; total is the value that
// means finished. Try other values.
//

$render(
  <vstack frame="max" padding="12">
    <text font="caption">Loading</text>
    <progress value="0.72" total="1" color="#3b82f6" />
    {/* style="circular" draws a ring; frame="32" makes it 32 by 32 points. */}
    <progress value="0.45" total="1" style="circular" color="#10b981" frame="32" />
  </vstack>,
);
