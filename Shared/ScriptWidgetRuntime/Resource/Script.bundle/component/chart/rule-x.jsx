//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component chart
// Horizontal lines: each entry runs from xstart to xend at the height y.
//

// One entry per line.
let data = [
  { xstart: 1, xend: 12, y: 2.5 },
  { xstart: 9, xend: 16, y: 1.5 },
  { xstart: 3, xend: 10, y: 0.5 },
];

// $json(data) is short for JSON.stringify(data): the chart takes its data as JSON text.
$render(
  <vstack frame="max">
    <chart
      type="rule-x" // required
      data={$json(data)} // required
      color="red" // optional , default black
      padding="20" // optional , general
    ></chart>
  </vstack>,
);
