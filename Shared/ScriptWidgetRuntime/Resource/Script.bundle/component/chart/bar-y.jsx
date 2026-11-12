// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for component chart
// 

let data = [
  { label:  "Production", value: 4000, category: "Gizmos" },
  { label:  "Production", value: 5000, category: "Gadgets" },
  { label:  "Production", value: 6000, category: "Widgets" },
]

$render(
  <vstack frame="max">
    <chart 
      type="bar-y" // required
      data={$json(data)} // required
      category={true}
      padding="20" // optional , general
      >
    </chart>
  </vstack>
);
