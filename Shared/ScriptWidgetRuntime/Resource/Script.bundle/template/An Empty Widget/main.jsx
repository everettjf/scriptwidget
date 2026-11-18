//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Empty Template
//
// Description: Empty script for starter
//
// The smallest useful starting point: one $render call with an icon and two texts.
// Try changing the texts, the icon name and the background color.
//

// The size being drawn: "small", "medium", "large", … It is shown in the badge.
const size = $getenv("widget-size");
// $render draws the JSX it is given. <vstack> stacks its children from top to bottom and
// <hstack> from left to right. frame="max" fills the whole widget; padding (the distance
// to the edges) and spacing (the gap between children) are in points.
$render(
  <vstack frame="max" alignment="leading" spacing="8" padding="16" background="#1d4ed8">
    <hstack>
      {/* systemName is the name of a system icon (an SF Symbol). */}
      <icon systemName="wand.and.stars" size="22" color="#60a5fa" />
      <spacer />
      <badge text={size} color="#93c5fd" />
    </hstack>
    {/* frame="max,bottomLeading" takes the remaining space and puts the text bottom left. */}
    <vstack frame="max,bottomLeading" alignment="leading" spacing="8">
      {/* The small widget gets a smaller title font. */}
      <text font={size === "small" ? "headline" : "title2"} weight="bold" color="white">
        Your next idea
      </text>
      <text font="caption" color="#94a3b8">
        Start editing this template to make it yours.
      </text>
    </vstack>
  </vstack>,
);
