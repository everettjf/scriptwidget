//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// basic clock animation
// A clock with three hands. The animation prop turns a view like a clock hand:
// "clockSecond" once a minute, "clockMinute" once an hour, "clockHour" once in 12 hours.
// Try other lengths and colors for the hands.
//

$render(
  <vstack frame="max,center">
    {/* <zstack> puts its children on top of each other, so the hands share one center. */}
    <zstack>
      {/* A hand is a colored bar above a clear bar of the same size ("width,height" in points). */}
      {/* The stack turns around its middle, which is the lower end of the colored bar. */}
      <vstack animation="clockSecond">
        <rect frame="5,50" color="yellow"></rect>
        <rect frame="5,50" color="clear"></rect>
      </vstack>
      <vstack animation="clockMinute">
        <rect frame="5,40" color="blue"></rect>
        <rect frame="5,40" color="clear"></rect>
      </vstack>
      <vstack animation="clockHour">
        <rect frame="5,30" color="red"></rect>
        <rect frame="5,30" color="clear"></rect>
      </vstack>
    </zstack>
  </vstack>,
);
