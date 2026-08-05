// widget-param: Plan,Deep work,Walk (optional)
const items = ($getenv("widget-param") || "Plan the day,Deep work,Take a walk").split(",").slice(0, 3);
$render(<vstack frame="max" alignment="leading" spacing="8" padding="14" background="#172554"><hstack frame="max"><text font="title3" weight="bold" color="white">Today</text><spacer/><date date="now" style="date" font="caption" color="#93c5fd"/></hstack>{items.map((item, i) => <hstack spacing="8"><badge text={String(i + 1)} color="#60a5fa"/><text font="callout" color="white">{item.trim()}</text><spacer/></hstack>)}</vstack>);
