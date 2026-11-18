//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// A fragment, written <>...</>, groups elements without adding a view of its own.
//

// Two texts kept in one variable.
var aaa = (
  <>
    <text>a text</text>
    <text>a text</text>
  </>
);

$render(
  <vstack frame="max">
    {/* The two texts become children of this stack, next to the third one. */}
    {aaa}
    <text>a text</text>
  </vstack>,
);
