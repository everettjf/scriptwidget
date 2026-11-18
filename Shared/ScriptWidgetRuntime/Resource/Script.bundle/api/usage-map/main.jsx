// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Mapping over an array
// Thanks for Reina for telling me this good idea
// Builds one <text> per array entry with map(). Try adding a value to the array.
//

const values = ["one", "two", "three", "four"];

// map() returns an array with one element per value.
const test = values.map((value) => {
  return <text>{value}</text>;
});

$render(
  <vstack>
    <text font="title">test</text>
    {/* An array of elements in braces is drawn as that many children. */}
    {test}
  </vstack>,
);
