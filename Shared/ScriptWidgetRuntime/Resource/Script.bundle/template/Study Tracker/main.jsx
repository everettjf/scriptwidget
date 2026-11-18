// widget-param: completed sessions,target (optional), e.g. 3,5
//
// This template shows a badge, a progress bar and a text that changes when the goal is
// reached. Try changing the default "3,5" or the two messages.

// $getenv("widget-param") is the parameter text set for this widget; "3,5" becomes [3, 5].
const v = ($getenv("widget-param") || "3,5").split(",").map(Number);
// A missing or non-numeric part falls back to 0 sessions done and a target of 5.
const done = v[0] || 0;
const target = v[1] || 5;
// frame="max" fills the widget; padding is the space around the content, in points.
$render(
  <vstack frame="max" alignment="leading" spacing="9" padding="14" background="#4338ca">
    <hstack frame="max">
      <icon systemName="graduationcap.fill" size="22" color="#e0e7ff" />
      <spacer />
      <badge text={`${done}/${target}`} color="#c7d2fe" />
    </hstack>
    <text font="title2" weight="bold" color="white">
      Study streak
    </text>
    <progress value={done} total={target} color="#a5b4fc" />
    {/* One of two messages, chosen with a ? : expression. */}
    <text font="caption" color="#e0e7ff">
      {done >= target ? "Goal complete — great work!" : `${target - done} sessions left today`}
    </text>
  </vstack>,
);
