
//
// ScriptWidget
// https://xnu.app/scriptwidget
//
//

const widget_size = $getenv("widget-size");
const widget_param = $getenv("widget-param");

const time = zone => new Date().toLocaleTimeString([], { timeZone: zone, hour: "2-digit", minute: "2-digit" });

$render(
  <vstack frame="max" spacing="8" padding="14" background="#111827">
    <hstack frame="max"><text font="headline" weight="bold" color="white">World Clock</text><spacer/><icon systemName="globe.americas.fill" size="20" color="#60a5fa"/></hstack>
    <hstack frame="max"><vstack alignment="leading"><text font="caption" color="#94a3b8">BEIJING</text><text font="title3" weight="bold" color="white">{time("Asia/Shanghai")}</text></vstack><spacer/><vstack alignment="leading"><text font="caption" color="#94a3b8">SAN JOSE</text><text font="title3" weight="bold" color="white">{time("America/Los_Angeles")}</text></vstack><spacer/><vstack alignment="leading"><text font="caption" color="#94a3b8">NEW YORK</text><text font="title3" weight="bold" color="white">{time("America/New_York")}</text></vstack></hstack>
  </vstack>
);
