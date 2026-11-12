//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// World Clock Faces: analog clocks for several cities. Edit `cities`
// with IANA time zone names.
//

const size = $getenv("widget-size");
const cities = [
  ["Cupertino", "America/Los_Angeles"], ["New York", "America/New_York"], ["London", "Europe/London"],
  ["Beijing", "Asia/Shanghai"], ["Tokyo", "Asia/Tokyo"], ["Sydney", "Australia/Sydney"],
];
const now = new Date();
// Wall-clock time in a zone, and its offset from here in hours.
const timeIn = (zone) => {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: zone, year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "2-digit", hourCycle: "h23" }).formatToParts(now);
  const value = (type) => Number(parts.find((part) => part.type === type)?.value ?? 0);
  const wall = Date.UTC(value("year"), value("month") - 1, value("day"), value("hour"), value("minute"));
  const here = Date.UTC(now.getFullYear(), now.getMonth(), now.getDate(), now.getHours(), now.getMinutes());
  return { hour: value("hour"), minute: value("minute"), hours: Math.round((wall - here) / 360000) / 10 };
};
const local = timeIn(Intl.DateTimeFormat().resolvedOptions().timeZone);
const offset = (time) => (time.hours === 0 ? "Local" : `${time.hours > 0 ? "+" : ""}${time.hours}H`);
const label = (time) => `${((time.hour + 11) % 12) + 1}:${String(time.minute).padStart(2, "0")} ${time.hour < 12 ? "AM" : "PM"}`;

// A hand is a capsule in the top half of a square that rotates about its center.
const Hand = ({ side, length, width, angle, color }) => (
  <vstack spacing="0" frame={`${width},${side}`} rotation={angle}>
    <spacer />
    <capsule frame={`${width},${length}`} color={color} />
    <rect color="clear" frame={`${width},${side / 2}`} />
  </vstack>
);
const Face = ({ time, side }) => {
  const day = time.hour >= 6 && time.hour < 18;
  const face = day ? "#F2F2F7" : "#1C1C1E";
  const ink = day ? "#1C1C1E" : "white";
  return (
    <zstack frame={`${side},${side}`}>
      <circle color={face} frame={`${side},${side}`} />
      {Array.from({ length: 12 }, (_, index) => (
        <vstack spacing="0" frame={`2,${side - 6}`} rotation={index * 30}>
          <capsule frame={`${index % 3 === 0 ? 2 : 1.5},${index % 3 === 0 ? side * 0.09 : side * 0.05}`} color={ink} opacity={index % 3 === 0 ? 1 : 0.4} />
          <spacer />
        </vstack>
      ))}
      <Hand side={side} length={side * 0.28} width={Math.max(2.5, side * 0.05)} angle={(time.hour % 12) * 30 + time.minute / 2} color={ink} />
      <Hand side={side} length={side * 0.4} width={Math.max(2, side * 0.035)} angle={time.minute * 6} color={ink} />
      <circle frame={`${side * 0.08},${side * 0.08}`} color="#FF9F0A" />
    </zstack>
  );
};
const City = ({ city, side, digital }) => {
  const time = timeIn(city[1]);
  return (
    <vstack spacing="4" frame="max">
      <Face time={time} side={side} />
      <text font="caption" fontWeight="semibold" color="white">{city[0]}</text>
      {digital ? <text font="subheadline" fontWeight="medium" color="white">{label(time)}</text> : null}
      <text font="caption2" color="#8E8E93">{offset(time)}</text>
    </vstack>
  );
};

if (size === "accessoryCircular") {
  $render(<Face time={local} side={60} />);
} else if (size === "accessoryRectangular") {
  $render(
    <vstack alignment="leading" spacing="1" frame="max,leading">
      {cities.slice(1, 4).map((city) => <hstack><text font="caption" fontWeight="semibold">{city[0]}</text><spacer /><text font="caption">{label(timeIn(city[1]))}</text></hstack>)}
    </vstack>
  );
} else if (size === "accessoryInline") {
  $render(<text>{cities[4][0]} {label(timeIn(cities[4][1]))}</text>);
} else if (size === "small") {
  const time = timeIn(cities[0][1]);
  $render(
    <vstack spacing="6" padding="12" background="black">
      <Face time={time} side={98} />
      <hstack><text font="caption" fontWeight="semibold" color="white">{cities[0][0]}</text><spacer /><text font="caption" color="#8E8E93">{label(time)}</text></hstack>
    </vstack>
  );
} else if (size === "medium") {
  $render(<hstack spacing="6" padding="14" background="black">{cities.slice(0, 4).map((city) => <City city={city} side={62} />)}</hstack>);
} else {
  const wide = size === "extraLarge";
  const grid = JSON.stringify(Array.from({ length: 3 }, () => ({ type: "flexible" })));
  $render(
    <vstack alignment="leading" spacing="12" padding="16" background="black">
      <text font="headline" color="white">World Clock</text>
      <vgrid columns={grid} spacing={wide ? 12 : 14}>{cities.map((city) => <City city={city} side={wide ? 84 : 70} digital />)}</vgrid>
      <spacer />
    </vstack>
  );
}
