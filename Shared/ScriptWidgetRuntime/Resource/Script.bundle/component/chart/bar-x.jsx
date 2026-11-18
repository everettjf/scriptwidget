//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component chart
// A single horizontal bar: the values are laid along the x axis; label is not used.
//

// Three values. category decides the color of each part.
let data = [
  { label: "Production", value: 4000, category: "Gizmos" },
  { label: "Production", value: 5000, category: "Gadgets" },
  { label: "Production", value: 6000, category: "Widgets" },
];

// $json(data) is short for JSON.stringify(data): the chart takes its data as JSON text.
$render(
  <vstack frame="max">
    <chart
      type="bar-x" // required
      data={$json(data)} // required
      category={true}
      padding="20" // optional , general
    ></chart>
  </vstack>,
);
