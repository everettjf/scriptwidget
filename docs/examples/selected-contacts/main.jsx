// Runtime 1.6; native grants are separate from this exported package.
if ($getenv("widget-size") !== "action") {
  try {
    const people = await $contacts.selected();
    const lines = people.length ? people.slice(0,2).map(person => person.name + (person.phones[0] ? " · " + person.phones[0] : "")) : ["Select contacts in System Access"];
    $render(<vstack alignment="leading" spacing="8" padding="16" background="#F2F8F5">
      <text font="headline" color="#153C30">People Close By</text>
      {lines.map(line => <text font="caption" color="#395C50">{line}</text>)}
    </vstack>);
  } catch (error) {
    console.error(String(error));
    $render(<vstack padding="16" spacing="8" background="#F2F8F5"><text font="headline" color="#153C30">People Close By</text><text font="caption" color="#395C50">Open this widget’s System Access in ScriptWidget, save access and authorize the system service.</text></vstack>);
  }
}
