// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for component date
// 

$render(
  <vstack>
    <date font="caption" date="now" style="time" />
    <date font="caption" date="now" style="date" />
    <date font="caption" date="start of today" style="timer" />
    <date font="title" date={Date.now()} style="timer" />
  </vstack>
);
