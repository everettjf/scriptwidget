// Connect this installed package through the native "iCloud Data" menu first.
// Choose a new store for isolation, or explicitly connect another widget to
// the same store ID to share note.json. JS cannot select that ID or a path.
// Shared widgets must agree on the schema and handle eventual-sync conflicts.
// Connecting does not migrate existing local $storage records.
// Writes are actions only; normal render never creates a cloud record.
async function syncNote() { await $icloud.sync(); }
async function saveNote() {
  const before = await $icloud.readJSON("note.json");
  if (before.state === "conflict") throw new Error("Review and resolve every conflicting version before saving.");
  await $icloud.writeJSON("note.json", {text: "Read a chapter"}, before.revision);
}
if ($getenv("widget-size") !== "action") {
  try {
    const note = await $icloud.readJSON("note.json");
    $render(
      <vstack alignment="leading" spacing="8" padding="16" background="#F2F8F5">
        <text font="headline" color="#163C35">iCloud Note</text>
        <text color="#163C35">{note.state === "conflict" ? "Conflicting versions need review" : note.value?.text ?? "No cached note yet"}</text>
        <text font="caption" color="#58776F">Cached data · upload status unknown</text>
        <hstack spacing="12">
          <button actionID="sync"><text color="#237B62">Sync</text></button>
          <button actionID="save"><text color="#237B62">Save note</text></button>
        </hstack>
      </vstack>
    );
  } catch (error) {
    console.error(String(error));
    $render(<text>Connect iCloud Data in ScriptWidget, then sync.</text>);
  }
}
