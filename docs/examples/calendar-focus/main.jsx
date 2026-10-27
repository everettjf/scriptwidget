// Runtime 1.6; native grants are separate from this exported package.
function requestID() { return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, c => { const r = Math.floor(Math.random() * 16); return (c === "x" ? r : (r & 3) | 8).toString(16); }); }
function pending(key, value) {
  const before = $storage.getString(key);
  if (before) return JSON.parse(before);
  $storage.compareAndSetString(key, "", JSON.stringify(value));
  const saved = $storage.getString(key);
  if (!saved) throw new Error("Could not save the request before the system write");
  return JSON.parse(saved);
}
async function createFocus() {
  const calendars = await $calendar.calendars();
  if (!calendars.length) throw new Error("Select a writable calendar in native Settings first");
  const start = new Date(Date.now() + 5 * 60000);
  const op = pending("focus.pending.v1", {requestID:requestID(),calendarID:calendars[0].id,title:"Focus time",start:start.toISOString(),end:new Date(start.getTime() + 30 * 60000).toISOString()});
  if (Date.now() - Date.parse(op.start) > 6 * 86400000) throw new Error("Inspect Calendar before retrying this old pending request");
  const result = await $calendar.create(op);
  if (!$storage.compareAndSetString("focus.pending.v1",JSON.stringify(op),"")) throw new Error("Saved to Calendar; local confirmation needs review");
}
if ($getenv("widget-size") !== "action") {
  try {
    const calendars = await $calendar.calendars();
    const lines = ["Add a 30-minute focus session", calendars.length ? "Calendar: " + calendars[0].title : "Select a calendar in Settings", "A new session starts five minutes after tapping."];
    $render(<vstack alignment="leading" spacing="8" padding="16" background="#F2F8F5">
      <text font="headline" color="#153C30">Focus Session</text>
      {lines.map(line => <text font="caption" color="#395C50">{line}</text>)}
      <hstack spacing="12"><button actionID="create"><text font="caption" color="#176A52">Add focus session</text></button></hstack>

    </vstack>);
  } catch (error) {
    console.error(String(error));
    $render(<vstack padding="16" spacing="8" background="#F2F8F5"><text font="headline" color="#153C30">Focus Session</text><text font="caption" color="#395C50">Open this widget’s System Access in ScriptWidget, save access and authorize the system service.</text></vstack>);
  }
}
