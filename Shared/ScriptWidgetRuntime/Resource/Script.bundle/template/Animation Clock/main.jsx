//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Animation Clock
// An analog clock whose hands are turned by the built-in clock animations.
// Try changing the colors and the lengths of the hands.
// The hands move on iPhone and iPad; a Mac shows them still, at the current time.
//

// Both layouts draw the same clock face.
// $getenv("widget-size") is the size being drawn: "small", "medium", "large", …
if ($getenv("widget-size") === "small") {
  // Small: the clock face with the time under it.
  $render(
    <vstack frame="max" spacing="6" padding="12" background="#111827">
      {/* The face. <zstack> draws its children on top of each other, centered. */}
      <zstack frame="112,112">
        <circle frame="108,108" color="#1f2937" />
        {/* A hand is a colored bar above a clear bar of the same size, so the pair turns around */}
        {/* the middle of the face. "clockSecond" makes one turn a minute, "clockMinute" one an */}
        {/* hour and "clockHour" one every 12 hours. */}
        <vstack animation="clockSecond">
          <rect frame="3,46" color="#fb7185" corner="2" />
          <rect frame="3,46" color="clear" />
        </vstack>
        <vstack animation="clockMinute">
          <rect frame="5,38" color="#60a5fa" corner="3" />
          <rect frame="5,38" color="clear" />
        </vstack>
        <vstack animation="clockHour">
          <rect frame="6,28" color="#f8fafc" corner="3" />
          <rect frame="6,28" color="clear" />
        </vstack>
        {/* The cap over the center. */}
        <circle frame="10,10" color="#f8fafc" />
      </zstack>
      {/* <date date="now" style="time" /> shows the current time. */}
      <date date="now" style="time" font="caption" weight="bold" color="white" />
    </vstack>,
  );
} else {
  // Medium and larger: the clock face on the left, the time and date on the right.
  $render(
    <hstack frame="max" spacing="18" padding="14" background="#111827">
      <zstack frame="112,112">
        <circle frame="108,108" color="#1f2937" />
        <vstack animation="clockSecond">
          <rect frame="3,46" color="#fb7185" corner="2" />
          <rect frame="3,46" color="clear" />
        </vstack>
        <vstack animation="clockMinute">
          <rect frame="5,38" color="#60a5fa" corner="3" />
          <rect frame="5,38" color="clear" />
        </vstack>
        <vstack animation="clockHour">
          <rect frame="6,28" color="#f8fafc" corner="3" />
          <rect frame="6,28" color="clear" />
        </vstack>
        <circle frame="10,10" color="#f8fafc" />
      </zstack>
      <vstack alignment="leading" spacing="4">
        <text font="caption" color="#94a3b8">
          ANALOG CLOCK
        </text>
        <date date="now" style="time" font="title2" weight="bold" color="white" />
        <date date="now" style="date" font="caption" color="#60a5fa" />
      </vstack>
    </hstack>,
  );
}
