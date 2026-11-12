//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for api storage
//

$storage.setString("greeting", "Hello ScriptWidget");
const greeting = $storage.getString("greeting");

$storage.setJSON("profile", {
  name: "Alex",
  city: "Shanghai",
  updatedAt: new Date().toISOString()
});
const profile = $storage.getJSON("profile");

const allKeys = $storage.keys();

$render(
  <vstack frame="max" background="#0f172a">
    <text font="caption" color="#94a3b8">Storage</text>
    <text font="title3" color="#e2e8f0">{greeting}</text>
    <text font="caption" color="#94a3b8">Name: {profile.name}</text>
    <text font="caption" color="#94a3b8">Keys: {allKeys.join(", ")}</text>
  </vstack>
);
