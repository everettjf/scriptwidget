// 
// ScriptWidget 
// https://xnu.app/scriptwidget
// 
// Clock Template
// 
// Description: Display Clock Time
// 

$render(
  <hstack background="#172554" frame="max" spacing="16" padding="14">
    <vstack alignment="leading" spacing="2"><text font="caption" color="#93c5fd">CURRENT TIME</text><date font="largeTitle" weight="bold" color="white" date="now" style="time"/><date font="caption" color="#bfdbfe" date="now" style="date"/></vstack>
    <spacer/><icon systemName="clock.fill" size="42" color="#60a5fa"/>
  </hstack>
);
