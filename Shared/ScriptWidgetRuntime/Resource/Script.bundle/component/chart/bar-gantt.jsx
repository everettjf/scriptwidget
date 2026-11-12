// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for component chart
// 

let data = [
  { job: "Job 1", start: 0, end: 15},
  { job: "Job 2", start: 5, end: 25},
  { job: "Job 1", start: 20, end: 35},
  { job: "Job 1", start: 40, end: 55},
  { job: "Job 2", start: 30, end: 60},
  { job: "Job 2", start: 30, end: 60},
]

$render(
  <vstack frame="max">
    <chart 
      type="bar-gantt" // required
      data={$json(data)} // required
      color="blue" // optional , default black
      padding="20" // optional , general
      >
    </chart>
  </vstack>
);
