// widget-param: your affirmation (optional)
// Shows one sentence in bold type. Try changing the default sentence or the colors.
//
// $getenv("widget-param") is the parameter set for this widget; the default text is used
// when it is empty.
const words = ($getenv("widget-param") || "I have everything I need for today.").trim();
// frame="max" fills the widget and alignment="leading" lines the children up on the
// left. padding and spacing are in points.
$render(
  <vstack frame="max" alignment="leading" spacing="8" padding="14" background="#7c3aed">
    <icon systemName="quote.opening" size="22" color="#ede9fe" />
    {/* frame="max,leading" gives the text the remaining space, aligned to the left. */}
    <text frame="max,leading" font="headline" weight="bold" color="white">
      {words}
    </text>
    <text font="caption" color="#f5f3ff">
      DAILY AFFIRMATION
    </text>
  </vstack>,
);
