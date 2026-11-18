// widget-param: focus minutes (optional)
const minutes = Math.max(5, Number($getenv("widget-param")) || 25);
if ($getenv("widget-size") === "small") {
  // Small: the length of the session.
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
      <progress value="0.2" total="1" color="#fda4af" />
    </vstack>,
  );
} else {
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
