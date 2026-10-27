// Runtime 1.6; native grants are separate from this exported package.
if ($getenv("widget-size") !== "action") {
  try {
    const history = await $health.dailyStatistics({metric:"steps",days:7});
    const lines = history.items.slice(-2).map(item => item.date.slice(5) + "  " + (item.hasSamples && item.value !== null ? Math.round(item.value).toLocaleString() + " steps" : "No shared samples"));
    $render(<vstack alignment="leading" spacing="8" padding="16" background="#F2F8F5">
      <text font="headline" color="#153C30">Seven Day Steps</text>
      {history.items.some(item => item.hasSamples && item.value !== null) && <chart type="bar" frame="max,48" hideLegend="true" hideXAxis="true" hideYAxis="true" color="#2D8B68" data={JSON.stringify(history.items.filter(item => item.hasSamples && item.value !== null).map(item => ({label:item.date.slice(5),value:item.value})))}/>}
      {lines.map(line => <text font="caption" color="#395C50">{line}</text>)}
    </vstack>);
  } catch (error) {
    console.error(String(error));
    $render(<vstack padding="16" spacing="8" background="#F2F8F5"><text font="headline" color="#153C30">Seven Day Steps</text><text font="caption" color="#395C50">Review Health access in native Settings.</text></vstack>);
  }
}
