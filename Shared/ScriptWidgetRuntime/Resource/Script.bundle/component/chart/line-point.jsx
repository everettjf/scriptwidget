// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for component chart
// 

let data = [
  { label: "jan/22", value: 5 },
  { label: "feb/22", value: 4 },
  { label: "mar/22", value: 7 },
  { label: "apr/22", value: 15 },
  { label: "may/22", value: 14 },
  { label: "jun/22", value: 27 },
  { label: "jul/22", value: 27 },
]

$render(
  <vstack frame="max">
    <chart 
      type="line-point" // required
      data={$json(data)} // required
      color="red" // optional , default black
      padding="20" // optional , general
      >
    </chart>
  </vstack>
);
