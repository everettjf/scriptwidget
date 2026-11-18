// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Template for component link
// 

if ($getenv("widget-size") === "small") {
  // Small: the name of the link, without the sentence that needs the width.
  $render(
    <vstack frame="max" alignment="leading" spacing="8" padding="14" background="#2563eb" linkurl="https://atomsprout.com/scriptwidget">
      <icon systemName="link" size="22" color="#60a5fa"/>
      <vstack frame="max,bottomLeading" alignment="leading" spacing="4"><text font="headline" weight="bold" color="white">ScriptWidget</text><text font="caption" color="#bfdbfe">TAP TO OPEN</text></vstack>
    </vstack>
  );
} else {
  $render(
    <vstack frame="max" alignment="leading" spacing="10" padding="14" background="#2563eb" linkurl="https://atomsprout.com/scriptwidget">
      <hstack frame="max"><icon systemName="link" size="22" color="#60a5fa"/><spacer/><text font="caption" color="#93c5fd">TAP TO OPEN</text></hstack>
      <spacer/><text font="title2" weight="bold" color="white">ScriptWidget</text><text font="caption" color="#bfdbfe">A full-card link with one simple URL.</text><spacer/>
    </vstack>
  );
}
