//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// grid component
// <hgrid> fills column after column. Its "columns" prop describes the rows.
// Try the other descriptions below, or more circles.
//

/*
iOS
{ type: "adaptive", min: "30"},
{ type: "fixed", value: "30"},
{ type: "flexible"},

macOS
{ type: "adaptive", min: "30", max: "100"},
{ type: "fixed", value: "30"},
{ type: "flexible"},

*/

// {} will default to { type: "flexible"},
// let columns = [
//     {},
//     {},
//     {},
//     {},
// ]

// let columns = [
//     { type: "fixed", value: "30"},
//     { type: "fixed", value: "30"},
//     { type: "fixed", value: "30"},
// ]

// One adaptive entry: as many rows as fit, each from 70 to 100 points.
let columns = [{ type: "adaptive", min: "70", max: "100" }];

// $json(columns) is short for JSON.stringify(columns): the prop takes JSON text.
$render(
  <vstack frame="max">
    <hgrid columns={$json(columns)}>
      <circle color="red" />
      <circle color="red" />
      <circle color="red" />
      <circle color="red" />
      <circle color="red" />
      <circle color="red" />
      <circle color="red" />
      <circle color="red" />
      <circle color="red" />
    </hgrid>
  </vstack>,
);
