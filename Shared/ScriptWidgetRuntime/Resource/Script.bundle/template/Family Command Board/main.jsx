// Designed for the large widget; the small and medium sizes show the essentials.
// widget-param: Family name|events comma-separated|chores comma-separated|dinner
// Try changing the default text below, or the colors.
//
// $getenv("widget-param") is the parameter set for this widget; the default is used when
// it is empty.
const parts = (
  $getenv("widget-param") ||
  "The Parkers|08:15 School drop-off,17:30 Soccer practice,19:00 Call Grandma|Mia · Feed Mochi,Noah · Recycling,All · Tidy kitchen|Taco bowls · 18:30"
).split("|");
// Take the four parts. filter(Boolean) drops empty entries; slice(0, 3) keeps three.
const family = (parts[0] || "Our Family").trim();
const events = (parts[1] || "").split(",").filter(Boolean).slice(0, 3);
const chores = (parts[2] || "").split(",").filter(Boolean).slice(0, 3);
const dinner = (parts[3] || "Plan dinner together").trim();
// One bar color for each of the three events.
const colors = ["#fb7185", "#fbbf24", "#60a5fa"];

// "08:15 School drop-off" is drawn as the time above the title, so both fit the half-width card.
const Event = ({ text, index }) => {
  // The first word is the time, when the text has more than one word.
  const words = text.trim().split(" ");
  const time = words.length > 1 ? words[0] : "";
  return (
    <hstack frame="max,leading" spacing="9">
      <rect frame="4,28" color={colors[index]} corner="2" />
      <vstack alignment="leading" spacing="0">
        {time ? (
          <text font="caption2" color="#fda4af">
            {time}
          </text>
        ) : null}
        <text font="caption" color="#f8fafc">
          {words.slice(time ? 1 : 0).join(" ")}
        </text>
      </vstack>
    </hstack>
  );
};

// Choose a layout for the widget size. `today` is a short date such as "Nov 18".
const size = $getenv("widget-size");
const today = new Date().toLocaleDateString("en-US", { month: "short", day: "numeric" });
if (size === "small") {
  // Small: the next event and dinner.
  $render(
    <vstack frame="max" alignment="leading" spacing="8" padding="14" background="#831843">
      <hstack spacing="6">
        <icon systemName="house.fill" size="16" color="#fb7185" />
        <text font="caption" weight="bold" color="#fda4af">
          TODAY
        </text>
        <spacer />
        <text font="caption2" color="#a1a1aa">
          {today}
        </text>
      </hstack>
      {events.length ? <Event text={events[0]} index={0} /> : null}
      {/* A card: its own background with rounded corners (`corner`, in points). */}
      {/* frame="max,52,leading" is full width, 52 points high, content on the left. */}
      <vstack
        frame="max,52,leading"
        alignment="leading"
        spacing="2"
        padding="9"
        background="#be185d"
        corner="12"
      >
        <hstack>
          <text font="caption2" weight="bold" color="#fce7f3">
            DINNER PLAN
          </text>
          <spacer />
        </hstack>
        <text font="caption" weight="semibold" color="white">
          {dinner}
        </text>
      </vstack>
    </vstack>,
  );
} else if (size === "medium") {
  // Medium: today's events beside the first chore and dinner.
  $render(
    <hstack frame="max" spacing="10" padding="14" background="#831843">
      <vstack
        frame="max,142,topLeading"
        alignment="leading"
        spacing="6"
        padding="10"
        background="#9d174d"
        corner="14"
      >
        <hstack frame="max">
          <text font="caption" weight="bold" color="#fda4af">
            TODAY
          </text>
          <spacer />
          <text font="caption2" color="#a1a1aa">
            {today}
          </text>
        </hstack>
        {events.map((item, i) => (
          <Event text={item} index={i} />
        ))}
      </vstack>
      <vstack frame="max,142" spacing="10">
        <vstack
          frame="max,66,topLeading"
          alignment="leading"
          spacing="6"
          padding="10"
          background="#9d174d"
          corner="14"
        >
          <hstack>
            <text font="caption" weight="bold" color="#fde68a">
              CHORES
            </text>
            <spacer />
            {/* The badge counts all chores; this size lists only the first one. */}
            <badge text={`${chores.length} LEFT`} color="#fbbf24" />
          </hstack>
          {chores.length ? (
            <hstack spacing="7">
              <circle frame="10,10" color="#3f3f46" />
              <text font="caption" color="#e4e4e7">
                {chores[0].trim()}
              </text>
            </hstack>
          ) : null}
        </vstack>
        <vstack
          frame="max,66,leading"
          alignment="leading"
          spacing="3"
          padding="10"
          background="#be185d"
          corner="14"
        >
          <hstack>
            <text font="caption2" weight="bold" color="#fce7f3">
              DINNER PLAN
            </text>
            <spacer />
          </hstack>
          <text font="caption" weight="semibold" color="white">
            {dinner}
          </text>
        </vstack>
      </vstack>
    </hstack>,
  );
} else {
  // Large and bigger: a header, events and chores side by side, dinner at the bottom.
  $render(
    <vstack frame="max" alignment="leading" spacing="12" padding="18" background="#831843">
      <hstack>
        <vstack alignment="leading" spacing="2">
          <text font="title2" weight="bold" color="white">
            {family}
          </text>
          <text font="caption" color="#a1a1aa">
            Home at a glance
          </text>
        </vstack>
        <spacer />
        <icon systemName="house.fill" size="26" color="#fb7185" />
      </hstack>
      <hstack frame="max" spacing="12">
        <vstack
          frame="max,158,topLeading"
          alignment="leading"
          spacing="9"
          padding="11"
          background="#9d174d"
          corner="14"
        >
          <hstack frame="max">
            <text font="caption" weight="bold" color="#fda4af">
              TODAY
            </text>
            <spacer />
            <text font="caption2" color="#a1a1aa">
              {new Date().toLocaleDateString("en-US", { month: "short", day: "numeric" })}
            </text>
          </hstack>
          {events.map((item, i) => (
            <Event text={item} index={i} />
          ))}
        </vstack>
        <vstack
          frame="max,158,topLeading"
          alignment="leading"
          spacing="9"
          padding="11"
          background="#9d174d"
          corner="14"
        >
          <hstack frame="max">
            <text font="caption" weight="bold" color="#fde68a">
              CHORES
            </text>
            <spacer />
            <badge text={`${chores.length} LEFT`} color="#fbbf24" />
          </hstack>
          {chores.map((item) => (
            <hstack frame="max,leading" spacing="7">
              <circle frame="10,10" color="#3f3f46" />
              <text font="caption" color="#e4e4e7">
                {item.trim()}
              </text>
            </hstack>
          ))}
        </vstack>
      </hstack>
      <hstack frame="max,72,leading" spacing="12" padding="13" background="#be185d" corner="14">
        <icon systemName="fork.knife" size="22" color="#fce7f3" />
        <vstack alignment="leading" spacing="2">
          <text font="caption2" weight="bold" color="#fce7f3">
            DINNER PLAN
          </text>
          <text font="headline" color="white">
            {dinner}
          </text>
        </vstack>
        <spacer />
      </hstack>
    </vstack>,
  );
}
