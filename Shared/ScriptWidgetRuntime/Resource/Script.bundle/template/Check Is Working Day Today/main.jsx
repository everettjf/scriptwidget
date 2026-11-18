//
// ScriptWidget
// https://atomsprout.com/scriptwidget
// Check Is Working Day Today
// Changes its colors, icon and text between working days and days off.
// Try changing which days count as working days.
//

var d = new Date();
// getDay() returns the day of the week: 0 is Sunday, 1 is Monday, … 6 is Saturday.
var n = d.getDay();
// console.log writes a line to the log, which helps while testing.
console.log(n);

// Monday to Friday.
const working = n >= 1 && n <= 5;
// Every color, icon and text below is chosen with `working ? … : …`.
// frame="max" fills the widget; padding and spacing are in points.
$render(
  <vstack
    background={working ? "#0f3d3e" : "#3b1d4a"}
    frame="max"
    alignment="leading"
    spacing="8"
    padding="14"
  >
    <hstack frame="max">
      <text font="caption" color={working ? "#99f6e4" : "#f5d0fe"}>
        DAY STATUS
      </text>
      <spacer />
      <text font="caption" color="white">
        {d.toLocaleDateString("en-US", { month: "short", day: "numeric" })}
      </text>
    </hstack>
    <spacer />
    <hstack spacing="10">
      <icon
        systemName={working ? "briefcase.fill" : "cup.and.saucer.fill"}
        size="28"
        color={working ? "#5eead4" : "#e879f9"}
      />
      <text font="title3" weight="bold" color="white">
        {working ? "Work day" : "Day off"}
      </text>
    </hstack>
    <text font="caption" color={working ? "#ccfbf1" : "#fae8ff"}>
      {working ? "Choose one meaningful priority." : "Rest, reset, and enjoy."}
    </text>
  </vstack>,
);
