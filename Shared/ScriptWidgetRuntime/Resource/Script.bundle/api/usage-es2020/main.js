//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Newer JavaScript syntax works in a widget script. This example uses ?? and ?. and
// prints the results to the Console.
//

// a ?? b gives b only when a is null or undefined.
const foo = null ?? "default string";
console.log(foo);
// expected output: "default string"

// 0 is a real value, so ?? keeps it.
const baz = 0 ?? 42;
console.log(baz);
// expected output: 0

const someArray = [0, 1, 2, 3];
console.log(someArray);

// Despite the name, nothing fails: reading past the end of an array gives undefined.
const thisWillError = someArray[5];
console.log(thisWillError);

// ?.[5] gives undefined too, and would not fail even if someArray were null.
const thisWillBeUndefined = someArray?.[5];
console.log(thisWillBeUndefined);

$render(
  <vstack frame="max">
    <text font="title">Hello ES2020</text>
  </vstack>,
);
