//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for api storage
// $storage keeps small values for this widget package between runs.
// A Package 2.0 widget must list "storage" under permissions in widget.json.
// Runs on iPhone, iPad, Mac, Android, Windows and Linux.
// Try: store a number and add 1 to it on every run.
//

// A text value. A key that was never set reads back as an empty string.
$storage.setString("greeting", "Hello ScriptWidget");
const greeting = $storage.getString("greeting");

// An object, stored as JSON. A missing key reads back as an empty object.
$storage.setJSON("profile", {
  name: "Alex",
  city: "Shanghai",
  updatedAt: new Date().toISOString(),
});
const profile = $storage.getJSON("profile");

// Every key this package has stored.
const allKeys = $storage.keys();

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max" background="#0f172a">
    <text font="caption" color="#94a3b8">
      Storage
    </text>
    <text font="title3" color="#e2e8f0">
      {greeting}
    </text>
    <text font="caption" color="#94a3b8">
      Name: {profile.name}
    </text>
    <text font="caption" color="#94a3b8">
      Keys: {allKeys.join(", ")}
    </text>
  </vstack>,
);
