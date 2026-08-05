// 
// ScriptWidget 
// https://xnu.app/scriptwidget
// 
// Empty Template
// 
// Description: Empty script for starter
// 

const size = $getenv("widget-size");
$render(
  <vstack frame="max" alignment="leading" spacing="8" padding="16" background="#0f172a">
    <hstack frame="max"><icon systemName="wand.and.stars" size="22" color="#60a5fa"/><spacer/><badge text={size} color="#93c5fd"/></hstack>
    <spacer/>
    <text font="title2" weight="bold" color="white">Your next idea</text>
    <text font="caption" color="#94a3b8">Start editing this template to make it yours.</text>
  </vstack>
);
