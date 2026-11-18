// widget-param: bedtime,wake time (optional)
//
// This template shows two texts from the widget parameter, with one layout for the small
// widget and one for the others. Try changing the default times or the colors.

// $getenv("widget-param") is the parameter text set for this widget, split at the comma.
const t = ($getenv("widget-param") || "10:30 PM,6:30 AM").split(",");
// $getenv("widget-size") is the size being drawn: "small", "medium", "large", …
if ($getenv("widget-size") === "small") {
  // Small: the two times under each other.
  // frame="max" fills the widget; padding is the space around the content, in points.
  $render(
    <vstack frame="max" alignment="leading" spacing="8" padding="14" background="#111827">
      <hstack>
        <text font="caption" weight="bold" color="#c4b5fd">
          SLEEP
        </text>
        <spacer />
        <icon systemName="moon.stars.fill" size="18" color="#c4b5fd" />
      </hstack>
      <vstack alignment="leading" spacing="1">
        <text font="caption2" color="#9ca3af">
          BEDTIME
        </text>
        <text font="headline" weight="bold" color="white">
          {t[0].trim()}
        </text>
      </vstack>
      <vstack alignment="leading" spacing="1">
        <text font="caption2" color="#9ca3af">
          WAKE UP
        </text>
        {/* The fallback covers a parameter with only one time in it. */}
        <text font="headline" weight="bold" color="white">
          {(t[1] || "6:30 AM").trim()}
        </text>
      </vstack>
    </vstack>,
  );
} else {
  // Medium and larger: the two times side by side, kept apart by <spacer />.
  $render(
    <vstack frame="max" spacing="10" padding="14" background="#111827">
      <hstack frame="max">
        <text font="headline" weight="bold" color="white">
          Sleep schedule
        </text>
        <spacer />
        <icon systemName="moon.stars.fill" size="21" color="#c4b5fd" />
      </hstack>
      <spacer />
      <hstack frame="max">
        <vstack>
          <text font="caption" color="#9ca3af">
            BEDTIME
          </text>
          <text font="title3" weight="bold" color="white">
            {t[0].trim()}
          </text>
        </vstack>
        <spacer />
        <vstack>
          <text font="caption" color="#9ca3af">
            WAKE UP
          </text>
          <text font="title3" weight="bold" color="white">
            {(t[1] || "6:30 AM").trim()}
          </text>
        </vstack>
      </hstack>
      <spacer />
    </vstack>,
  );
}
