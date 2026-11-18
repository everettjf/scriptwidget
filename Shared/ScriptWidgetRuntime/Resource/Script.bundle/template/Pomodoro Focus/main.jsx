// widget-param: focus minutes (optional)
//
// This template shows a number read from the widget parameter, with its own layout for
// the small widget. The progress bar is a fixed sample; nothing counts down.
// Try changing the default of 25 minutes or the colors.

// $getenv("widget-param") is the parameter text set for this widget. An empty or
// non-numeric parameter gives 25, and anything below 5 becomes 5.
const minutes = Math.max(5, Number($getenv("widget-param")) || 25);
// $getenv("widget-size") is the size being drawn: "small", "medium", "large", …
if ($getenv("widget-size") === "small") {
  // Small: the length of the session.
  // frame="max" fills the widget; padding is the space around the content, in points.
  $render(
    <vstack frame="max" alignment="leading" spacing="6" padding="14" background="#be123c">
      <hstack spacing="6">
        <icon systemName="timer" size="18" color="#ffe4e6" />
        <text font="caption" weight="bold" color="#ffe4e6">
          FOCUS
        </text>
      </hstack>
      <vstack frame="max,leading" alignment="leading" spacing="2">
        <text font="largeTitle" weight="bold" color="white">
          {minutes}:00
        </text>
        <text font="caption" color="#ffe4e6">
          One task at a time.
        </text>
      </vstack>
      {/* The bar is fixed at 20%; it does not follow a timer. */}
      <progress value="0.2" total="1" color="#fda4af" />
    </vstack>,
  );
} else {
  // Medium and larger: the same parts, with <spacer /> elements pushing them apart.
  $render(
    <vstack frame="max" spacing="10" padding="14" background="#be123c">
      <hstack frame="max">
        <icon systemName="timer" size="20" color="#ffe4e6" />
        <text font="headline" weight="bold" color="white">
          Focus session
        </text>
        <spacer />
      </hstack>
      <spacer />
      <text font="largeTitle" weight="bold" color="white">
        {minutes}:00
      </text>
      <text font="caption" color="#ffe4e6">
        One task. No distractions.
      </text>
      <spacer />
      <progress value="0.2" total="1" color="#fda4af" />
    </vstack>,
  );
}
