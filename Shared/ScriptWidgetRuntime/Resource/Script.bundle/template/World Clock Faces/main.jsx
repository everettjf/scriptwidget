//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// World Clock Faces: analog clocks for several cities. Edit `cities`
// with IANA time zone names.
//

// $getenv("widget-size") is the size being drawn: "small", "medium", "large", …
const size = $getenv("widget-size");
// Each city: [the name to show, its IANA time zone].
const cities = [
  ["Cupertino", "America/Los_Angeles"],
  ["New York", "America/New_York"],
  ["London", "Europe/London"],
  ["Beijing", "Asia/Shanghai"],
  ["Tokyo", "Asia/Tokyo"],
  ["Sydney", "Australia/Sydney"],
];
const now = new Date();
// Wall-clock time in a zone, and its offset from here in hours.
const timeIn = (zone) => {
  // Intl.DateTimeFormat gives the date and time as a clock in that zone shows them.
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: zone,
    year: "numeric",
    month: "numeric",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(now);
  const value = (type) => Number(parts.find((part) => part.type === type)?.value ?? 0);
  // Put both clock readings on the same scale; their difference is the offset.
  const wall = Date.UTC(
    value("year"),
    value("month") - 1,
    value("day"),
    value("hour"),
    value("minute"),
  );
  const here = Date.UTC(
    now.getFullYear(),
    now.getMonth(),
    now.getDate(),
    now.getHours(),
    now.getMinutes(),
  );
  return {
    hour: value("hour"),
    minute: value("minute"),
    // 360000 ms is a tenth of an hour, so this is the offset in hours with one decimal.
    hours: Math.round((wall - here) / 360000) / 10,
  };
};
// The time here, for the Lock Screen face.
const local = timeIn(Intl.DateTimeFormat().resolvedOptions().timeZone);
// offset: "Local", "+8H" or "-3H". label: a 12-hour time such as "9:05 PM".
const offset = (time) =>
  time.hours === 0 ? "Local" : `${time.hours > 0 ? "+" : ""}${time.hours}H`;
const label = (time) =>
  `${((time.hour + 11) % 12) + 1}:${String(time.minute).padStart(2, "0")} ${time.hour < 12 ? "AM" : "PM"}`;

// A hand is a capsule in the top half of a square that rotates about its center.
const Hand = ({ side, length, width, angle, color }) => (
  <vstack spacing="0" frame={`${width},${side}`} rotation={angle}>
    <spacer />
    <capsule frame={`${width},${length}`} color={color} />
    <rect color="clear" frame={`${width},${side / 2}`} />
  </vstack>
);
// A clock face: a disc, twelve tick marks and two hands. It is light from 6:00 to 18:00
// in that city and dark at night. `side` is its width and height in points.
const Face = ({ time, side }) => {
  const day = time.hour >= 6 && time.hour < 18;
  const face = day ? "#F2F2F7" : "#1C1C1E";
  const ink = day ? "#1C1C1E" : "white";
  return (
    <zstack frame={`${side},${side}`}>
      <circle color={face} frame={`${side},${side}`} />
      {/* Twelve ticks, 30 degrees apart; every third one is longer and darker. */}
      {Array.from({ length: 12 }, (_, index) => (
        <vstack spacing="0" frame={`2,${side - 6}`} rotation={index * 30}>
          <capsule
            frame={`${index % 3 === 0 ? 2 : 1.5},${index % 3 === 0 ? side * 0.09 : side * 0.05}`}
            color={ink}
            opacity={index % 3 === 0 ? 1 : 0.4}
          />
          <spacer />
        </vstack>
      ))}
      {/* Hour hand: 30 degrees for each hour and half a degree for each minute. */}
      <Hand
        side={side}
        length={side * 0.28}
        width={Math.max(2.5, side * 0.05)}
        angle={(time.hour % 12) * 30 + time.minute / 2}
        color={ink}
      />
      {/* Minute hand: 6 degrees for each minute. */}
      <Hand
        side={side}
        length={side * 0.4}
        width={Math.max(2, side * 0.035)}
        angle={time.minute * 6}
        color={ink}
      />
      <circle frame={`${side * 0.08},${side * 0.08}`} color="#FF9F0A" />
    </zstack>
  );
};
// A face with the city's name, the digital time if wanted, and the offset.
const City = ({ city, side, digital }) => {
  const time = timeIn(city[1]);
  return (
    <vstack spacing="4" frame="max">
      <Face time={time} side={side} />
      <text font="caption" fontWeight="semibold" color="white">
        {city[0]}
      </text>
      {digital ? (
        <text font="subheadline" fontWeight="medium" color="white">
          {label(time)}
        </text>
      ) : null}
      <text font="caption2" color="#8E8E93">
        {offset(time)}
      </text>
    </vstack>
  );
};

// Choose a layout for the widget size. The "accessory" sizes are Lock Screen widgets
// (iPhone and iPad only).
if (size === "accessoryCircular") {
  $render(<Face time={local} side={60} />);
} else if (size === "accessoryRectangular") {
  $render(
    <vstack alignment="leading" spacing="1" frame="max,leading">
      {cities.slice(1, 4).map((city) => (
        <hstack>
          <text font="caption" fontWeight="semibold">
            {city[0]}
          </text>
          <spacer />
          <text font="caption">{label(timeIn(city[1]))}</text>
        </hstack>
      ))}
    </vstack>,
  );
} else if (size === "accessoryInline") {
  $render(
    <text>
      {cities[4][0]} {label(timeIn(cities[4][1]))}
    </text>,
  );
} else if (size === "small") {
  // Small: the first city. padding is the space around the content, in points.
  const time = timeIn(cities[0][1]);
  $render(
    <vstack spacing="6" padding="12" background="black">
      <Face time={time} side={98} />
      <hstack>
        <text font="caption" fontWeight="semibold" color="white">
          {cities[0][0]}
        </text>
        <spacer />
        <text font="caption" color="#8E8E93">
          {label(time)}
        </text>
      </hstack>
    </vstack>,
  );
} else if (size === "medium") {
  // Medium: the first four cities in a row.
  $render(
    <hstack spacing="6" padding="14" background="black">
      {cities.slice(0, 4).map((city) => (
        <City city={city} side={62} />
      ))}
    </hstack>,
  );
} else {
  // Large and extra large: all six cities in a grid of three columns. <vgrid> takes its
  // columns as a JSON string.
  const wide = size === "extraLarge";
  const grid = JSON.stringify(Array.from({ length: 3 }, () => ({ type: "flexible" })));
  $render(
    <vstack alignment="leading" spacing="12" padding="16" background="black">
      <text font="headline" color="white">
        World Clock
      </text>
      <vgrid columns={grid} spacing={wide ? 12 : 14}>
        {cities.map((city) => (
          <City city={city} side={70} digital />
        ))}
      </vgrid>
      <spacer />
    </vstack>,
  );
}
