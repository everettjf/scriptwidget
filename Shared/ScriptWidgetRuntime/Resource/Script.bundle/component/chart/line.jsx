//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component chart
// A line chart: the points joined by a line. Try other values.
//

// One entry per point: label goes on the x axis, value on the y axis.
let data = [
  { label: "jan/22", value: 5 },
  { label: "feb/22", value: 4 },
  { label: "mar/22", value: 7 },
  { label: "apr/22", value: 15 },
  { label: "may/22", value: 14 },
  { label: "jun/22", value: 27 },
  { label: "jul/22", value: 27 },
];

// $json(data) is short for JSON.stringify(data): the chart takes its data as JSON text.
$render(
  <vstack frame="max">
    <chart
      type="line" // required
      data={$json(data)} // required
      color="red" // optional , default black
      padding="20" // optional , general
    ></chart>
  </vstack>,
);
