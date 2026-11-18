// A list that scrolls inside the widget, which only Android can do.
// Every row is a toggle that keeps its own state in package storage.
// iPhone widgets cannot scroll, so the first rows are shown there.
const items = [
  "Water the plants",
  "Reply to Sam",
  "Book the dentist",
  "Renew the library card",
  "Back up the photos",
  "Order printer ink",
  "Call the plumber",
  "Pay the electricity bill",
  "Plan the weekend trip",
  "Clean the keyboard",
  "Update the budget",
  "Return the parcel",
  "Charge the camera",
  "Sort the bookshelf",
  "Write to grandma",
  "Check the tire pressure",
  "Buy a birthday card",
  "Defrost the freezer",
  "Review the notes",
  "Stretch for ten minutes",
];
const android = $system.platform() === "android";
const size = $getenv("widget-size");
const done = items.map((_, index) => $storage.getString("check." + index) === "true");
const count = done.filter(Boolean).length;

const row = (title, index) => (
  <toggle stateKey={"check." + index} on={done[index]} padding="4,2,4,2">
    <text
      font="subheadline"
      color={done[index] ? "material.onSurfaceVariant" : "material.onSurface"}
    >
      {title}
    </text>
  </toggle>
);

const rows = android ? (
  <list spacing="2">{items.map(row)}</list>
) : (
  <vstack alignment="leading" spacing="4">
    {items.slice(0, size === "large" ? 7 : 2).map(row)}
  </vstack>
);

$render(
  <vstack
    frame="max,topLeading"
    alignment="leading"
    spacing="8"
    padding="14"
    background="material.surfaceContainer"
  >
    <hstack>
      <text font="headline" color="material.onSurface">
        Checklist
      </text>
      <spacer />
      <text font="caption" color="material.primary">
        {count + " of " + items.length}
      </text>
    </hstack>
    {rows}
  </vstack>,
);
