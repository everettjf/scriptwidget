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
async function startTimer() {
  const op = pending("timer.pending.v1",{requestID:requestID(),key:"focus",title:"Focus complete",seconds:1500});
  await $alarms.schedule(op);
  if (!$storage.compareAndSetString("timer.pending.v1",JSON.stringify(op),"")) throw new Error("Timer scheduled; review local confirmation before retrying");
}
async function cancelTimer() { await $alarms.cancel("focus"); }
async function pauseTimer() { await $alarms.pause("focus"); }
async function resumeTimer() { await $alarms.resume("focus"); }
if ($getenv("widget-size") !== "action") {
  const lines = ["25 minutes, one thing at a time"];
  try {
    const status = await $alarms.status();
    // AlarmKit authorization is process-scoped on some iOS versions. Widget
    // actions run in the app; keep controls visible when extension reads differ.
    if (status.authorization === "authorized") {
      const timers = await $alarms.pending();
      lines.push(...timers.filter(item => item.key === "focus").slice(0,1).map(item => item.key + " · " + item.state));
    } else {
      lines.push("Start checks app alarm access");
    }
  } catch (error) {
    console.error(String(error));
    lines.push("Review System Access in ScriptWidget");
  }
  $render(<vstack alignment="leading" spacing="8" padding="16" background="#F2F8F5">
      <text font="headline" color="#153C30">Focus Timer</text>
      {lines.map(line => <text font="caption" color="#395C50">{line}</text>)}
      <hstack spacing="12"><button actionID="start"><text font="caption" color="#176A52">Start 25 min</text></button><button actionID="pause"><text font="caption" color="#176A52">Pause</text></button><button actionID="resume"><text font="caption" color="#176A52">Resume</text></button><button actionID="cancel"><text font="caption" color="#176A52">Cancel</text></button></hstack>

    </vstack>);
}
