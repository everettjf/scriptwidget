// widget-param: saved,target (optional), e.g. 1250,3000
//
// This template shows an amount, a progress bar and a percentage, all from the widget
// parameter. Try changing the default "1250,3000" or the "$" sign.

// $getenv("widget-param") is the parameter text set for this widget; "1250,3000" becomes
// [1250, 3000]. A missing or non-numeric part falls back to 0 saved and a target of 3000.
const values = ($getenv("widget-param") || "1250,3000").split(",").map(Number);
const saved = values[0] || 0;
const target = values[1] || 3000;
// $render draws the widget: call it once with one root element.
// frame="max" fills the widget; padding is the space around the content, in points.
$render(
  <vstack frame="max" alignment="leading" spacing="9" padding="14" background="#0f766e">
    <hstack frame="max">
      <text font="headline" weight="bold" color="white">
        Savings
      </text>
      <spacer />
      <icon systemName="banknote.fill" size="20" color="#ccfbf1" />
    </hstack>
    {/* In JSX text "$" is an ordinary character; {…} inserts a JavaScript value. */}
    <text font="title2" weight="bold" color="white">
      ${saved.toLocaleString()}
    </text>
    <progress value={saved} total={target} color="#5eead4" />
    <text font="caption" color="#ccfbf1">
      {Math.round((saved / target) * 100)}% of ${target.toLocaleString()} goal
    </text>
  </vstack>,
);
