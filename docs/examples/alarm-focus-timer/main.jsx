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
  try {
    const status = await $alarms.status();
    const timers = await $alarms.pending();
    const lines = ["25 minutes, one thing at a time", "Authorization: " + status.authorization, ...timers.filter(item => item.key === "focus").slice(0,1).map(item => item.key + " · " + item.state)];
    $render(<vstack alignment="leading" spacing="8" padding="16" background="#F2F8F5">
      <text font="headline" color="#153C30">Focus Timer</text>
      {lines.map(line => <text font="caption" color="#395C50">{line}</text>)}
      <hstack spacing="12"><button actionID="start"><text font="caption" color="#176A52">Start 25 min</text></button><button actionID="pause"><text font="caption" color="#176A52">Pause</text></button><button actionID="resume"><text font="caption" color="#176A52">Resume</text></button><button actionID="cancel"><text font="caption" color="#176A52">Cancel</text></button></hstack>

    </vstack>);
  } catch (error) {
    console.error(String(error));
    $render(<vstack padding="16" spacing="8" background="#F2F8F5"><text font="headline" color="#153C30">Focus Timer</text><text font="caption" color="#395C50">Open this widget’s System Access in ScriptWidget, save access and authorize the system service.</text></vstack>);
  }
}
