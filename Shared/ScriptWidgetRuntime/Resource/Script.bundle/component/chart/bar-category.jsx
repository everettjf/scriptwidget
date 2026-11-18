//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component chart
// A bar chart with colored groups. category={true} colors the bars by their category.
//

// Three labels with three entries each. Entries with the same label share one place
// on the x axis; category decides the color.
let data = [
  { label: "Production", value: 4000, category: "Gizmos" },
  { label: "Production", value: 5000, category: "Gadgets" },
  { label: "Production", value: 6000, category: "Widgets" },
  { label: "Marketing", value: 2000, category: "Gizmos" },
  { label: "Marketing", value: 1000, category: "Gadgets" },
  { label: "Marketing", value: 5000.9, category: "Widgets" },
  { label: "Finance", value: 2000.5, category: "Gizmos" },
  { label: "Finance", value: 3000, category: "Gadgets" },
  { label: "Finance", value: 5000, category: "Widgets" },
];

// $json(data) is short for JSON.stringify(data): the chart takes its data as JSON text.
$render(
  <vstack frame="max">
    <chart
      type="bar" // required
      data={$json(data)} // required
      category={true}
      padding="20" // optional , general
    ></chart>
  </vstack>,
);
