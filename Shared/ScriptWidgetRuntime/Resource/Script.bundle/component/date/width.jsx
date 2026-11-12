// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for component date
// try to fix the expanding issue , we can add a frame attribute : frame="50,max,leading"
//

$render(
  <hstack alignment="center">
    <text font="10" color="#aaaaaa,0.5">
      Last update:
    </text>
    <date font="10" color="#aaaaaa,0.5" date={Date.now()} frame="50,max,leading" />
  </hstack>
);
