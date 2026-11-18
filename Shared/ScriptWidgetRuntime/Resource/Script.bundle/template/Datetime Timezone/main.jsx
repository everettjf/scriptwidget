//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
//

const widget_size = $getenv("widget-size");
const widget_param = $getenv("widget-param");

const time = (zone) =>
  new Date().toLocaleTimeString([], { timeZone: zone, hour: "2-digit", minute: "2-digit" });

if (widget_size === "small") {
  // Small: one city on each line.
  const City = ({ name, zone }) => (
    <hstack>
      <text font="caption" color="#94a3b8">
        {name}
      </text>
      <spacer />
      <text font="footnote" weight="bold" color="white">
        {time(zone)}
      </text>
    </hstack>
  );
  $render(
    <vstack frame="max" alignment="leading" spacing="10" padding="14" background="#111827">
      <hstack>
        <text font="subheadline" weight="bold" color="white">
          World Clock
        </text>
        <spacer />
        <icon systemName="globe.americas.fill" size="18" color="#60a5fa" />
      </hstack>
      <City name="BEIJING" zone="Asia/Shanghai" />
      <City name="SAN JOSE" zone="America/Los_Angeles" />
      <City name="NEW YORK" zone="America/New_York" />
    </vstack>,
  );
} else {
  $render(
    <vstack frame="max" spacing="8" padding="14" background="#111827">
      <hstack frame="max">
        <text font="headline" weight="bold" color="white">
          World Clock
        </text>
        <spacer />
        <icon systemName="globe.americas.fill" size="20" color="#60a5fa" />
      </hstack>
      <hstack frame="max">
        <vstack alignment="leading">
          <text font="caption" color="#94a3b8">
            BEIJING
          </text>
          <text font="headline" weight="bold" color="white">
            {time("Asia/Shanghai")}
          </text>
        </vstack>
        <spacer />
        <vstack alignment="leading">
          <text font="caption" color="#94a3b8">
            SAN JOSE
          </text>
          <text font="headline" weight="bold" color="white">
            {time("America/Los_Angeles")}
          </text>
        </vstack>
        <spacer />
        <vstack alignment="leading">
          <text font="caption" color="#94a3b8">
            NEW YORK
          </text>
          <text font="headline" weight="bold" color="white">
            {time("America/New_York")}
          </text>
        </vstack>
      </hstack>
    </vstack>,
  );
}
