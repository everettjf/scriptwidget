// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for api $fetch
// 

// query json example with header
// https://docs.github.com/en/rest/reference/projects

const url = "https://api.github.com/users/everettjf/orgs";
const result = await fetch(url, {
  headers: {
    Accept: "application/vnd.github.inertia-preview+json",
  },
});
console.log(result);

const models = JSON.parse(result);

$render(
  <vstack>
    <text font="caption">Org Description: {models[2].description}</text>
  </vstack>
);
