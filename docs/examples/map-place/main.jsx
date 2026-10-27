// Runtime 1.6; native grants are separate from this exported package.
if ($getenv("widget-size") !== "action") {
  try {
    const places = await $maps.search({query:"park",latitude:37.33,longitude:-122.01,radiusMeters:3000});
    const lines = places.length ? places.slice(0,3).map(place => place.name.slice(0,36)) : ["No matching places"];
    $render(<vstack alignment="leading" spacing="8" padding="16" background="#F2F8F5">
      <text font="headline" color="#153C30">A Place to Go</text>
      {lines.map(line => <text font="caption" color="#395C50">{line}</text>)}
    </vstack>);
  } catch (error) {
    console.error(String(error));
    $render(<vstack padding="16" spacing="8" background="#F2F8F5"><text font="headline" color="#153C30">A Place to Go</text><text font="caption" color="#395C50">Open this widget’s System Access in ScriptWidget, save access and authorize the system service.</text></vstack>);
  }
}
