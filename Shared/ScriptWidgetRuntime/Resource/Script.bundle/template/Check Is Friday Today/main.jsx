//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
//

var d = new Date();
var n = d.getDay();
console.log(n);

$render(
  <vstack background="#4f46e5" frame="max" alignment="leading" spacing="8" padding="14">
    <hstack frame="max">
      <text font="caption" color="#c4b5fd">
        FRIDAY CHECK
      </text>
      <spacer />
      <text font="caption" color="#ddd6fe">
        {d.toLocaleDateString("en-US", { month: "short", day: "numeric" })}
      </text>
    </hstack>
    <spacer />
    <hstack spacing="10">
      <icon systemName={n == 5 ? "party.popper.fill" : "calendar"} size="28" color="#fbbf24" />
      <text font="title2" weight="bold" color="white">
        {n == 5 ? "Yes!" : "Not yet"}
      </text>
    </hstack>
    <text font="caption" color="#ddd6fe">
      {n == 5 ? "The weekend starts here." : `${(5 - n + 7) % 7} days to go.`}
    </text>
  </vstack>,
);
