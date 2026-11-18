//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for component chart
// A Gantt chart: a bar from start to end for every entry, in the row of its job.
//

// start and end are positions on the x axis. Entries with the same job share a row.
let data = [
  { job: "Job 1", start: 0, end: 15 },
  { job: "Job 2", start: 5, end: 25 },
  { job: "Job 1", start: 20, end: 35 },
  { job: "Job 1", start: 40, end: 55 },
  { job: "Job 2", start: 30, end: 60 },
  { job: "Job 2", start: 30, end: 60 },
];

// $json(data) is short for JSON.stringify(data): the chart takes its data as JSON text.
$render(
  <vstack frame="max">
    <chart
      type="bar-gantt" // required
      data={$json(data)} // required
      color="blue" // optional , default black
      padding="20" // optional , general
    ></chart>
  </vstack>,
);
