//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for api $fetch
// Loads one JSON document and shows its title. Try another URL and another field.
// A Package 2.0 widget needs the "network" permission in widget.json, and the host
// of the URL in networkDomains.
// Runs on iPhone, iPad, Mac, Android, Windows and Linux.
//

// query json example
// https://jsonplaceholder.typicode.com/

const url = "https://jsonplaceholder.typicode.com/todos/1";
// fetch gives back the body of the response as text.
const result = await fetch(url);
console.log(result);

// Turn the JSON text into an object.
const model = JSON.parse(result);

$render(
  <vstack>
    <text font="title">receive title: {model.title}</text>
  </vstack>,
);
