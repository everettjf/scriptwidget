// Runtime 1.6; native grants are separate from this exported package.
if ($getenv("widget-size") !== "action") {
  try {
    const weather = await $weather.forecast({latitude:37.33,longitude:-122.01,hours:6});
    const lines = weather.hours.slice(0,2).map(item => item.time.slice(11,16) + "  " + Math.round(item.temperatureC) + "°C · " + item.windMetersPerSecond + " m/s");
    lines.push(weather.isStale ? "Cached forecast · may be out of date" : "Forecast fetched " + weather.fetchedAt.slice(11,16));
    $render(<vstack alignment="leading" spacing="8" padding="16" background="#F2F8F5">
      <text font="headline" color="#153C30">Weather Ahead</text>
      {lines.map(line => <text font="caption" color="#395C50">{line}</text>)}

      <link url={weather.attribution.url}><text font="caption2" color="#526F66">{weather.attribution.text}</text></link>
    </vstack>);
  } catch (error) {
    console.error(String(error));
    $render(<vstack padding="16" spacing="8" background="#F2F8F5"><text font="headline" color="#153C30">Weather Ahead</text><text font="caption" color="#395C50">Open this widget’s System Access in ScriptWidget, save access and authorize the system service.</text></vstack>);
  }
}
