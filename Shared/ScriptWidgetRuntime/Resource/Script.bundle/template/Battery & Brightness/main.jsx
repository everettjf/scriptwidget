//
// ScriptWidget
// https://xnu.app/scriptwidget
//
// Battery & Brightness
//

const battery = $device.battery();
const brightness = $system.brightness();
const percent = (battery.level * 100).toFixed(0);

$render(
  <hstack frame="max" spacing="18" padding="16" background="#111827">
    <vstack alignment="leading" spacing="6">
      <hstack spacing="6"><icon systemName="battery.100" size="18" color="#4ade80"/><text font="caption" weight="bold" color="#86efac">BATTERY</text></hstack>
      <text font="largeTitle" weight="bold" color="white">{percent}%</text>
      <badge text={battery.state} color="#4ade80"/>
    </vstack>
    <spacer/>
    <rect frame="1,104" color="#334155"/>
    <spacer/>
    <vstack alignment="leading" spacing="6">
      <hstack spacing="6"><icon systemName="sun.max.fill" size="18" color="#38bdf8"/><text font="caption" weight="bold" color="#7dd3fc">DISPLAY</text></hstack>
      <text font="largeTitle" weight="bold" color="white">{brightness >= 0 ? Math.round(brightness * 100) + "%" : "—"}</text>
      <text font="caption" color="#94a3b8">Brightness</text>
    </vstack>
  </hstack>
);
