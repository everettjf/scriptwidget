//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for api $fetch
// Loads JSON with a request header and shows one field of it. Try another URL.
// A Package 2.0 widget needs the "network" permission in widget.json, and the host
// of the URL in networkDomains.
// Runs on iPhone, iPad, Mac, Android, Windows and Linux.
//

// query json example with header
// https://docs.github.com/en/rest/reference/projects

const url = "https://api.github.com/users/everettjf/orgs";
// fetch gives back the body of the response as text. headers are sent with the request.
const result = await fetch(url, {
  headers: {
    Accept: "application/vnd.github.inertia-preview+json",
  },
});
console.log(result);

// Turn the JSON text into a JavaScript value: here an array.
const models = JSON.parse(result);

// models[2] is the third entry. With fewer than three entries, or without a network,
// the script fails here; a real widget should draw a fallback instead.
$render(
  <vstack>
    <text font="caption">Org Description: {models[2].description}</text>
  </vstack>,
);
