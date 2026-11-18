//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component date
// try to fix the expanding issue , we can add a frame attribute : frame="50,max,leading"
// Left alone, a <date> takes all the width it can get. A fixed width keeps it by the label.
//

$render(
  <hstack alignment="center">
    {/* font="10" is a size in points; "#aaaaaa,0.5" is a color with 50% opacity. */}
    <text font="10" color="#aaaaaa,0.5">
      Last update:
    </text>
    {/* frame="50,max,leading": 50 points wide, full height, content at the leading edge. */}
    <date font="10" color="#aaaaaa,0.5" date={Date.now()} frame="50,max,leading" />
  </hstack>,
);
