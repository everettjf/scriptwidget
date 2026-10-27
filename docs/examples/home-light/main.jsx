// Runtime 1.6; native grants are separate from this exported package.
async function lightOn() { const items = await $home.items(); const item = items.find(x => x.kind === "power"); if (!item) throw new Error("Select a light in System Access"); await $home.setPower({id:item.id,on:true}); }
async function lightOff() { const items = await $home.items(); const item = items.find(x => x.kind === "power"); if (!item) throw new Error("Select a light in System Access"); await $home.setPower({id:item.id,on:false}); }
if ($getenv("widget-size") !== "action") {
  try {
    const items = await $home.items();
    const lines = items.length ? items.slice(0,2).map(item => item.name.slice(0,28) + " · " + (item.value === null ? "Unknown" : String(item.value))) : ["Select Home items in System Access"];
    lines.push("HomeKit cached readings");
    $render(<vstack alignment="leading" spacing="8" padding="16" background="#F2F8F5">
      <text font="headline" color="#153C30">A Calmer Home</text>
      {lines.map(line => <text font="caption" color="#395C50">{line}</text>)}
      <hstack spacing="12"><button actionID="on"><text font="caption" color="#176A52">Light on</text></button><button actionID="off"><text font="caption" color="#176A52">Light off</text></button></hstack>

    </vstack>);
  } catch (error) {
    console.error(String(error));
    $render(<vstack padding="16" spacing="8" background="#F2F8F5"><text font="headline" color="#153C30">A Calmer Home</text><text font="caption" color="#395C50">Open this widget’s System Access in ScriptWidget, save access and authorize the system service.</text></vstack>);
  }
}
