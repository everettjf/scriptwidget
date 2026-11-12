
//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
//



const foo = null ?? 'default string';
console.log(foo);
// expected output: "default string"

const baz = 0 ?? 42;
console.log(baz);
// expected output: 0

const someArray = [0, 1, 2, 3];
console.log(someArray);

const thisWillError = someArray[5];
console.log(thisWillError);

const thisWillBeUndefined = someArray?.[5];
console.log(thisWillBeUndefined);

$render(
  <vstack frame="max">
    <text font="title">Hello ES2020</text>
  </vstack>
);
