// widget-param: breakfast,lunch,dinner (optional)
// Shows three meals for today. Try changing the default meals, the labels or the color.
// $getenv("widget-param") is the optional widget parameter, a text you set on each widget
// you place. It is empty when nothing was set, so the defaults are used.
const meals = ($getenv("widget-param") || "Oatmeal,Grain bowl,Pasta").split(",");
const labels = ["Morning", "Lunch", "Dinner"];
$render(
  <vstack frame="max" alignment="leading" spacing="7" padding="14" background="#c2410c">
    <hstack frame="max" spacing="0">
      <text font="headline" weight="bold" color="white">
        Today's menu
      </text>
      <spacer />
      <icon systemName="fork.knife" size="16" color="#ffedd5" />
    </hstack>
    {/* One row per label. A meal that is missing from the parameter shows as "Flexible". */}
    {labels.map((label, i) => (
      <hstack frame="max">
        <text font="caption" color="#fed7aa">
          {label}
        </text>
        <spacer />
        <text font="callout" weight="semibold" color="white">
          {(meals[i] || "Flexible").trim()}
        </text>
      </hstack>
    ))}
  </vstack>,
);
