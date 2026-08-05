// 
// ScriptWidget 
// https://xnu.app/scriptwidget
// 
// Content Select Template
// 
// Description: Choose content at runtime
// 

const widget_size = $getenv("widget-size");
const morning = new Date().getHours() < 12;
const content = morning
  ? <hstack spacing="8"><icon systemName="sun.max.fill" size="28" color="#fbbf24"/><vstack alignment="leading"><text font="title2" weight="bold" color="white">Good morning</text><text font="caption" color="#bfdbfe">Start with what matters.</text></vstack></hstack>
  : <hstack spacing="8"><icon systemName="moon.stars.fill" size="28" color="#c4b5fd"/><vstack alignment="leading"><text font="title2" weight="bold" color="white">Good evening</text><text font="caption" color="#ddd6fe">Make space to unwind.</text></vstack></hstack>;

$render(
  <vstack frame="max" alignment="leading" spacing="10" padding="14" background={morning ? "#1e3a8a" : "#312e81"}>
    <hstack frame="max"><text font="caption" color="#bfdbfe">CONDITIONAL CONTENT</text><spacer/><badge text={widget_size} color="#dbeafe"/></hstack>
    <spacer/>{content}<spacer/>
  </vstack>
);
