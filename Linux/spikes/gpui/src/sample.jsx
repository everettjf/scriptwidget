// ScriptWidget sample: weather card
const city = $storage.getString("city") || "Hangzhou";
const scale = $device.screenScale;

async function load() {
  const res = await fetch(`https://api.example.com/weather?q=${city}`);
  if (!res.ok) {
    throw new Error("HTTP " + res.status);
  }
  return res.json();
}

const data = await load();
const temps = data.hourly.map((h) => h.temp);
const title = "今天多云 " + data.now.temp + "°C";

$render(
  <vstack frame="max" padding="16" spacing="8" background="#1e3c72">
    <hstack spacing="6">
      <image systemName="cloud.sun.fill" color="yellow" />
      <text font="title3" color="white">{title}</text>
      <spacer />
      <text font="caption" color="#ffffffaa">{city}</text>
    </hstack>
    <chart type="line" data={temps} color="#78ffbe" frame="max,60" />
    <hstack>
      {data.daily.slice(0, 3).map((d) => (
        <text font="caption2" color="white">{d.day}: {d.low}~{d.high}</text>
      ))}
    </hstack>
  </vstack>
);
