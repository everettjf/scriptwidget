// Designed for the large widget; the small and medium sizes show the essentials. widget-param: flight|origin|destination|departure|gate|weather|essentials comma-separated
const parts = (
  $getenv("widget-param") ||
  "SW 218|SFO|SEA|10:40 AM|B12|58° · Light rain|Passport,Headphones,Charger"
).split("|");
const flight = parts[0] || "SW 218";
const origin = parts[1] || "SFO";
const destination = parts[2] || "SEA";
const departure = parts[3] || "10:40 AM";
const gate = parts[4] || "B12";
const weather = parts[5] || "58° · Light rain";
const essentials = (parts[6] || "Passport,Headphones,Charger").split(",").slice(0, 3);

const size = $getenv("widget-size");
if (size === "small") {
  // Small: the route, the departure time and the gate.
  $render(
    <vstack frame="max" alignment="leading" spacing="8" padding="14" background="#075985">
      <hstack>
        <badge text={flight} color="#38bdf8" />
        <spacer />
        <icon systemName="airplane" size="18" color="#38bdf8" />
      </hstack>
      <text font="title3" weight="bold" color="white">
        {origin} → {destination}
      </text>
      <vstack
        frame="max,52,leading"
        alignment="leading"
        spacing="2"
        padding="9"
        background="#10253a"
        corner="12"
      >
        <hstack>
          <text font="caption2" color="#64748b">
            GATE {gate}
          </text>
          <spacer />
        </hstack>
        <text font="subheadline" weight="semibold" color="white">
          {departure}
        </text>
      </vstack>
    </vstack>,
  );
} else if (size === "medium") {
  // Medium: the route above the departure, the gate and the weather.
  $render(
    <vstack frame="max" alignment="leading" spacing="8" padding="14" background="#075985">
      <hstack spacing="8" padding="10" background="#0369a1" corner="15">
        <vstack alignment="leading" spacing="2">
          <text font="title2" weight="bold" color="white">
            {origin}
          </text>
          <text font="caption" color="#7dd3fc">
            DEPART
          </text>
        </vstack>
        <spacer />
        <vstack spacing="5">
          <badge text={flight} color="#38bdf8" />
          <rect frame="72,2" color="#164e63" corner="1" />
        </vstack>
        <spacer />
        <vstack alignment="trailing" spacing="2">
          <text font="title2" weight="bold" color="white">
            {destination}
          </text>
          <text font="caption" color="#7dd3fc">
            ARRIVE
          </text>
        </vstack>
      </hstack>
      <hstack spacing="8">
        <vstack
          frame="max,56,leading"
          alignment="leading"
          spacing="3"
          padding="9"
          background="#10253a"
          corner="12"
        >
          <text font="caption2" color="#64748b">
            DEPARTURE
          </text>
          <text font="subheadline" weight="semibold" color="white">
            {departure}
          </text>
        </vstack>
        <vstack
          frame="max,56,leading"
          alignment="leading"
          spacing="3"
          padding="9"
          background="#10253a"
          corner="12"
        >
          <text font="caption2" color="#64748b">
            GATE
          </text>
          <text font="subheadline" weight="semibold" color="white">
            {gate}
          </text>
        </vstack>
        <vstack
          frame="max,56,leading"
          alignment="leading"
          spacing="3"
          padding="9"
          background="#10253a"
          corner="12"
        >
          <hstack>
            <text font="caption2" color="#64748b">
              DESTINATION
            </text>
            <spacer />
          </hstack>
          <text font="subheadline" weight="semibold" color="white">
            {weather}
          </text>
        </vstack>
      </hstack>
    </vstack>,
  );
} else {
  $render(
    <vstack frame="max" alignment="leading" spacing="10" padding="16" background="#075985">
      <hstack>
        <vstack alignment="leading" spacing="2">
          <text font="title2" weight="bold" color="white">
            Travel Day
          </text>
          <text font="caption" color="#7dd3fc">
            Everything before boarding
          </text>
        </vstack>
        <spacer />
        <badge text={flight} color="#38bdf8" />
      </hstack>
      <hstack spacing="8" padding="10" background="#0369a1" corner="15">
        <vstack alignment="leading" spacing="2">
          <text font="title" weight="bold" color="white">
            {origin}
          </text>
          <text font="caption" color="#7dd3fc">
            DEPART
          </text>
        </vstack>
        <spacer />
        <vstack spacing="5">
          <icon systemName="airplane" size="24" color="#38bdf8" />
          <rect frame="72,2" color="#164e63" corner="1" />
        </vstack>
        <spacer />
        <vstack alignment="trailing" spacing="2">
          <text font="title" weight="bold" color="white">
            {destination}
          </text>
          <text font="caption" color="#7dd3fc">
            ARRIVE
          </text>
        </vstack>
      </hstack>
      <hstack spacing="8">
        <vstack
          frame="max,56,leading"
          alignment="leading"
          spacing="3"
          padding="9"
          background="#10253a"
          corner="12"
        >
          <text font="caption2" color="#64748b">
            DEPARTURE
          </text>
          <text font="subheadline" weight="semibold" color="white">
            {departure}
          </text>
        </vstack>
        <vstack
          frame="max,56,leading"
          alignment="leading"
          spacing="3"
          padding="9"
          background="#10253a"
          corner="12"
        >
          <text font="caption2" color="#64748b">
            GATE
          </text>
          <text font="subheadline" weight="semibold" color="white">
            {gate}
          </text>
        </vstack>
        <vstack
          frame="max,56,leading"
          alignment="leading"
          spacing="3"
          padding="9"
          background="#10253a"
          corner="12"
        >
          <hstack>
            <text font="caption2" color="#64748b">
              DESTINATION
            </text>
            <spacer />
          </hstack>
          <text font="subheadline" weight="semibold" color="white">
            {weather}
          </text>
        </vstack>
      </hstack>
      <vstack alignment="leading" spacing="5" padding="11" background="#10253a" corner="14">
        <hstack>
          <text font="caption" weight="bold" color="#bae6fd">
            BEFORE YOU GO
          </text>
          <spacer />
          <icon systemName="checklist" size="15" color="#38bdf8" />
        </hstack>
        {essentials.map((item) => (
          <hstack spacing="9">
            <circle frame="10,10" color="#164e63" />
            <text font="caption" color="#e0f2fe">
              {item.trim()}
            </text>
            <spacer />
            <text font="caption2" color="#38bdf8">
              PACKED?
            </text>
          </hstack>
        ))}
      </vstack>
    </vstack>,
  );
}
