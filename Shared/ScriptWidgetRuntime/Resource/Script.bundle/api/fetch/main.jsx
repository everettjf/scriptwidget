// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for api $fetch
// 

// query json example
// https://jsonplaceholder.typicode.com/

const url = "https://jsonplaceholder.typicode.com/todos/1";
const result = await fetch(url);
console.log(result);

const model = JSON.parse(result);

$render(
  <vstack>
    <text font="title">receive title: {model.title}</text>
  </vstack>
);
