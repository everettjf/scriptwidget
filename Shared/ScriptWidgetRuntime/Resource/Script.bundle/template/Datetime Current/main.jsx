// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Clock Template
// 
// Description: Display Clock Time
// 

if ($getenv("widget-size") === "small") {
  // Small: the time, with a short date that fits the narrow widget.
  $render(
    <vstack background="#172554" frame="max" alignment="leading" spacing="4" padding="14">
      <hstack><text font="caption" color="#93c5fd">CURRENT TIME</text><spacer/><icon systemName="clock.fill" size="18" color="#60a5fa"/></hstack>
      <vstack frame="max,leading" alignment="leading" spacing="2">
        <date font="title2" weight="bold" color="white" date="now" style="time"/>
        <text font="caption" color="#bfdbfe">{new Date().toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" })}</text>
      </vstack>
    </vstack>
  );
} else {
  $render(
    <hstack background="#172554" frame="max" spacing="16" padding="14">
      <vstack alignment="leading" spacing="2"><text font="caption" color="#93c5fd">CURRENT TIME</text><date font="largeTitle" weight="bold" color="white" date="now" style="time"/><date font="caption" color="#bfdbfe" date="now" style="date"/></vstack>
      <spacer/><icon systemName="clock.fill" size="42" color="#60a5fa"/>
    </hstack>
  );
}
