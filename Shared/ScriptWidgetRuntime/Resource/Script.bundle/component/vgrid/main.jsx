
//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// grid component
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

let columns = [
    { type: "adaptive", min: "70", max: "100"},
]

$render(
  <vstack frame="max">
    <vgrid columns={$json(columns)}>
        <circle color="red"/>
        <circle color="red"/>
        <circle color="red"/>
        <circle color="red"/>
        <circle color="red"/>
        <circle color="red"/>
        <circle color="red"/>
        <circle color="red"/>
        <circle color="red"/>
    </vgrid>
  </vstack>
);
