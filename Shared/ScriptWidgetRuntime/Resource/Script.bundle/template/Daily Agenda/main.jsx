// widget-param: Plan,Deep work,Walk (optional)
// Shows up to three items as a numbered list. Try changing the default items.
//
// Split the parameter (or the default, when it is empty) at the commas and keep the first
// three items.
const items = ($getenv("widget-param") || "Plan the day,Deep work,Take a walk")
  .split(",")
  .slice(0, 3);
// frame="max" fills the widget; padding and spacing are in points.
$render(
  <vstack frame="max" alignment="leading" spacing="8" padding="14" background="#2563eb">
    <hstack frame="max">
      <text font="title3" weight="bold" color="white">
        Today
      </text>
      <spacer />
      {/* <date date="now" style="date" /> shows today's date. */}
      <date date="now" style="date" font="caption" color="#dbeafe" />
    </hstack>
    {/* One row for each item: map turns the list of texts into a list of elements. */}
    {items.map((item, i) => (
      <hstack spacing="8">
        <badge text={String(i + 1)} color="#bfdbfe" />
        <text font="callout" color="white">
          {item.trim()}
        </text>
        <spacer />
      </hstack>
    ))}
  </vstack>,
);
