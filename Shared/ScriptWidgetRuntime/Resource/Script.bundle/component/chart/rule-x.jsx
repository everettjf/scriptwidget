// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for component chart
// 

let data = [
  { xstart: 1, xend: 12, y: 2.5 },
  { xstart: 9, xend: 16, y: 1.5 },
  { xstart: 3, xend: 10, y: 0.5 },
]

$render(
  <vstack frame="max">
    <chart 
      type="rule-x" // required
      data={$json(data)} // required
      color="red" // optional , default black
      padding="20" // optional , general
      >
    </chart>
  </vstack>
);
