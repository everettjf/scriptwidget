//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Datetime Timezone
// Shows the time in three cities. Try changing the cities and their time zone names.
//

// The size being drawn, and the widget's parameter (read here, but not used below).
const widget_size = $getenv("widget-size");
const widget_param = $getenv("widget-param");

// The time in a zone such as "Asia/Shanghai", as hours and minutes in the device's own
// format. The text is worked out when the script runs.
const time = (zone) =>
  new Date().toLocaleTimeString([], { timeZone: zone, hour: "2-digit", minute: "2-digit" });

if (widget_size === "small") {
  // Small: one city on each line.
  // A component for one line: the city on the left, its time on the right.
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
  // Medium and larger: the three cities side by side.
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
