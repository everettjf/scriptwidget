//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Content Select Template
//
// Description: Choose content at runtime
//
// Shows that JSX can be kept in a variable and chosen with ordinary JavaScript.
// Try changing the hour, or adding a third case.
//

// The size being drawn ("small", "medium", "large", …); it is shown in the badge.
const widget_size = $getenv("widget-size");
// true before noon.
const morning = new Date().getHours() < 12;
// Two blocks of JSX. Only the chosen one is put into the widget below.
const content = morning ? (
  <vstack alignment="leading" spacing="6">
    <icon systemName="sun.max.fill" size="28" color="#fbbf24" />
    <vstack alignment="leading">
      <text font="headline" weight="bold" color="white">
        Good morning
      </text>
      <text font="caption" color="#bfdbfe">
        Start with what matters.
      </text>
    </vstack>
  </vstack>
) : (
  <vstack alignment="leading" spacing="6">
    <icon systemName="moon.stars.fill" size="28" color="#c4b5fd" />
    <vstack alignment="leading">
      <text font="headline" weight="bold" color="white">
        Good evening
      </text>
      <text font="caption" color="#ddd6fe">
        Make space to unwind.
      </text>
    </vstack>
  </vstack>
);

// $render draws the widget. frame="max" fills it; padding and spacing are in points.
$render(
  <vstack
    frame="max"
    alignment="leading"
    spacing="10"
    padding="14"
    background={morning ? "#1e3a8a" : "#312e81"}
  >
    <hstack frame="max">
      <text font="caption" color="#bfdbfe">
        CONDITION
      </text>
      <spacer />
      <badge text={widget_size} color="#dbeafe" />
    </hstack>
    <spacer />
    {/* The chosen block goes here. The spacers above and below center it vertically. */}
    {content}
    <spacer />
  </vstack>,
);
