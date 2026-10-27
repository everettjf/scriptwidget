// Runtime 1.6; native grants are separate from this exported package.
if ($getenv("widget-size") !== "action") {
  try {
    const files = await $documents.list();
    const file = files.find(item => item.type === "json");
    const data = file ? await $documents.readJSON(file.id) : null;
    const lines = file ? [file.name, JSON.stringify(data).slice(0,180)] : ["Import a JSON file in System Access", "The original file stays unchanged."];
    $render(<vstack alignment="leading" spacing="8" padding="16" background="#F2F8F5">
      <text font="headline" color="#153C30">My JSON Data</text>
      {lines.map(line => <text font="caption" color="#395C50">{line}</text>)}
    </vstack>);
  } catch (error) {
    console.error(String(error));
    $render(<vstack padding="16" spacing="8" background="#F2F8F5"><text font="headline" color="#153C30">My JSON Data</text><text font="caption" color="#395C50">Open this widget’s System Access in ScriptWidget, save access and authorize the system service.</text></vstack>);
  }
}
