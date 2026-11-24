// The weekday and seven steps from Monday to Sunday. There is no network request.
// Use the planned entry's date so a widget prepared before midnight shows the right day.
const now = new Date($getenv("timeline-date") || Date.now());
const weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const day = (now.getDay() + 6) % 7;
const date = `${months[now.getMonth()]} ${now.getDate()}`;
const small = $getenv("widget-size") === "small";
const dark = $device.isdarkmode();
const background = dark ? "#17283B" : "#E8F1FA";
const ink = dark ? "#EFF7FF" : "#132E4A";
const muted = dark ? "#ADC4DD" : "#405D7C";
const accent = dark ? "#80D6FF" : "#005F91";
const past = dark ? "#416D91" : "#9BBFDC";
const track = dark ? "#304255" : "#CBD9E7";

// The highlighted block marks today. Earlier blocks show the days already passed.
$render(
  <vstack frame="max" alignment="leading" padding="14" spacing="5" background={background}>
    <hstack spacing="5">
      <icon systemName="calendar" size="13" color={accent} />
      <text font="caption" color={muted}>
        Week progress
      </text>
    </hstack>
    <spacer />
    <text font={small ? "title3" : "title"} weight="bold" color={ink}>
      {weekdays[day]}
    </text>
    <text font="caption" color={muted}>
      {date}
    </text>
    <spacer />
    <hstack spacing={small ? "4" : "7"}>
      {weekdays.map((weekday, index) => (
        <vstack spacing="3">
          <rect
            frame={small ? "13,5" : "27,6"}
            corner="2"
            color={index === day ? accent : index < day ? past : track}
          />
          <text
            font="caption2"
            weight={index === day ? "bold" : "regular"}
            color={index === day ? accent : muted}
          >
            {small ? weekday.slice(0, 1) : weekday.slice(0, 3)}
          </text>
        </vstack>
      ))}
    </hstack>
    <text font="caption2" color={muted}>{`Day ${day + 1} of 7`}</text>
  </vstack>,
);
