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
  { label:  "Marketing", value: 2000, category: "Gizmos" },
  { label:  "Marketing", value: 1000, category: "Gadgets" },
  { label:  "Marketing", value: 5000.9, category: "Widgets" },
  { label:  "Finance", value: 2000.5, category: "Gizmos" },
  { label:  "Finance", value: 3000, category: "Gadgets" },
  { label:  "Finance", value: 5000, category: "Widgets" },
]

$render(
  <vstack frame="max">
    <chart 
      type="line" // required
      data={$json(data)} // required
      category={true}
      padding="20" // optional , general
      >
    </chart>
  </vstack>
);
