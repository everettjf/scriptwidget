// Runtime 1.6; native grants are separate from this exported package.
async function scheduleReminder() { await $notifications.schedule({key:"reading",title:"Time to read",body:"One chapter is enough to keep going.",daily:{hour:20,minute:0}}); }
async function cancelReminder() { await $notifications.cancel("reading"); }
if ($getenv("widget-size") !== "action") {
  try {
    const status = await $notifications.status();
    const items = await $notifications.pending();
    const lines = ["Authorization: " + status.authorization, items.length ? "Reading reminder scheduled" : "No reminder scheduled"];
    $render(<vstack alignment="leading" spacing="8" padding="16" background="#F2F8F5">
      <text font="headline" color="#153C30">Reading Reminder</text>
      {lines.map(line => <text font="caption" color="#395C50">{line}</text>)}
      <hstack spacing="12"><button actionID="schedule"><text font="caption" color="#176A52">Remind at 20:00</text></button><button actionID="cancel"><text font="caption" color="#176A52">Cancel</text></button></hstack>

    </vstack>);
  } catch (error) {
    console.error(String(error));
    $render(<vstack padding="16" spacing="8" background="#F2F8F5"><text font="headline" color="#153C30">Reading Reminder</text><text font="caption" color="#395C50">Open this widget’s System Access in ScriptWidget, save access and authorize the system service.</text></vstack>);
  }
}
