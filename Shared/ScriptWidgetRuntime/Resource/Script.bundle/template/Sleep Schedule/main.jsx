// widget-param: bedtime,wake time (optional)
const t = ($getenv("widget-param") || "10:30 PM,6:30 AM").split(",");
if ($getenv("widget-size") === "small") {
  // Small: the two times under each other.
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
        <text font="headline" weight="bold" color="white">
          {(t[1] || "6:30 AM").trim()}
        </text>
      </vstack>
    </vstack>,
  );
} else {
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
