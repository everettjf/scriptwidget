//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// grid component
// <vgrid> fills row after row. columns describes its columns.
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

// One adaptive entry: as many columns as fit, each from 70 to 100 points.
let columns = [{ type: "adaptive", min: "70", max: "100" }];

// $json(columns) is short for JSON.stringify(columns): the prop takes JSON text.
$render(
  <vstack frame="max">
    <vgrid columns={$json(columns)}>
      <circle color="red" />
      <circle color="red" />
      <circle color="red" />
      <circle color="red" />
      <circle color="red" />
      <circle color="red" />
      <circle color="red" />
      <circle color="red" />
      <circle color="red" />
    </vgrid>
  </vstack>,
);
