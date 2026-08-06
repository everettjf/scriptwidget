// widget-param: Plan,Deep work,Walk (optional)
const items = ($getenv("widget-param") || "Plan the day,Deep work,Take a walk").split(",").slice(0, 3);
$render(<vstack frame="max" alignment="leading" spacing="8" padding="14" background="#2563eb"><hstack frame="max"><text font="title3" weight="bold" color="white">Today</text><spacer/><date date="now" style="date" font="caption" color="#dbeafe"/></hstack>{items.map((item, i) => <hstack spacing="8"><badge text={String(i + 1)} color="#bfdbfe"/><text font="callout" color="white">{item.trim()}</text><spacer/></hstack>)}</vstack>);
