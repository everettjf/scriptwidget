//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// another basic clock animation
// Three dots that go round like the hands of a clock. The animation prop turns a view:
// "clockHour" once in 12 hours, "clockMinute" once an hour, "clockSecond" once a minute.
// Try other sizes and colors.
//

$render(
  <vstack frame="max,center">
    {/* <zstack> puts its children on top of each other, so all three turn around one center. */}
    <zstack>
      {/* The <spacer /> pushes the dot to the top of its stack, away from the center. */}
      <vstack animation="clockHour">
        <circle frame="15,15" color="red"></circle>
        <spacer />
      </vstack>
      <vstack animation="clockMinute">
        <circle frame="10,10" color="blue"></circle>
        <spacer />
      </vstack>
      <vstack animation="clockSecond">
        <circle frame="5,5" color="yellow"></circle>
        <spacer />
      </vstack>
    </zstack>
  </vstack>,
);
