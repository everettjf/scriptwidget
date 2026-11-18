//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Battery & Brightness
//
// Shows two device readings. Try changing the colors or adding a third reading.
//

// Read the data. $device.battery() returns { level, state }: level goes from 0 to 1 and
// state is a word such as "unplugged". $system.brightness() is the screen brightness,
// also from 0 to 1.
const battery = $device.battery();
const brightness = $system.brightness();
// The level as a whole-number percentage, as text: for example "80".
const percent = (battery.level * 100).toFixed(0);

// $getenv("widget-size") is the size being drawn: "small", "medium", "large", …
if ($getenv("widget-size") === "small") {
  // Small: the battery level, with the brightness as one line under it.
  $render(
    <vstack frame="max" alignment="leading" spacing="6" padding="14" background="#111827">
      <hstack spacing="6">
        <icon systemName="battery.100" size="18" color="#4ade80" />
        <text font="caption" weight="bold" color="#86efac">
          BATTERY
        </text>
        <spacer />
      </hstack>
      <text font="largeTitle" weight="bold" color="white">
        {percent}%
      </text>
      <badge text={battery.state} color="#4ade80" />
      {/* A Mac reports a brightness of -1 (unknown), so a dash is shown for a negative value. */}
      <hstack spacing="6">
        <icon systemName="sun.max.fill" size="14" color="#38bdf8" />
        <text font="caption" color="#7dd3fc">
          {brightness >= 0 ? Math.round(brightness * 100) + "% display" : "Display —"}
        </text>
      </hstack>
    </vstack>,
  );
} else {
  // Medium and larger: battery on the left, brightness on the right, a line between.
  $render(
    <hstack frame="max" spacing="18" padding="16" background="#111827">
      <vstack alignment="leading" spacing="6">
        <hstack spacing="6">
          <icon systemName="battery.100" size="18" color="#4ade80" />
          <text font="caption" weight="bold" color="#86efac">
            BATTERY
          </text>
        </hstack>
        <text font="largeTitle" weight="bold" color="white">
          {percent}%
        </text>
        <badge text={battery.state} color="#4ade80" />
      </vstack>
      <spacer />
      <rect frame="1,104" color="#334155" />
      <spacer />
      <vstack alignment="leading" spacing="6">
        <hstack spacing="6">
          <icon systemName="sun.max.fill" size="18" color="#38bdf8" />
          <text font="caption" weight="bold" color="#7dd3fc">
            DISPLAY
          </text>
        </hstack>
        <text font="largeTitle" weight="bold" color="white">
          {brightness >= 0 ? Math.round(brightness * 100) + "%" : "—"}
        </text>
        <text font="caption" color="#94a3b8">
          Brightness
        </text>
      </vstack>
    </hstack>,
  );
}
