//
// ScriptWidget 
// https://xnu.app/scriptwidget
// 
// Battery Percent Template
// 


var percent = $device.battery().level * 100;
percent = percent.toFixed(0);

$render(
  <hstack background="#0f766e" frame="max" spacing="16" padding="14">
    <vstack alignment="leading" spacing="4"><text font="caption" color="#5eead4">DEVICE BATTERY</text><text font="largeTitle" weight="bold" color="white">{percent}%</text><text font="caption" color="#99f6e4">Power at a glance</text></vstack>
    <spacer/><ring value={Number(percent)/100} thickness="10" color="#2dd4bf" trackColor="#134e4a" frame="82,82"/>
  </hstack>
);
