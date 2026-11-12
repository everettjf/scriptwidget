// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for component guage
// 

$render(
  <vstack frame="max">
    <gauge 
      type="system"
      value="0.6"
      text="hello" // not display
      current="60"
      style="circular" // default
      >
    </gauge>
  </vstack>
);
