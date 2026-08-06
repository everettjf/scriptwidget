// Large widget. widget-param: flight|origin|destination|departure|gate|weather|essentials comma-separated
const parts = ($getenv("widget-param") || "SW 218|SFO|SEA|10:40 AM|B12|58° · Light rain|Passport,Headphones,Charger").split("|");
const flight = parts[0] || "SW 218";
const origin = parts[1] || "SFO";
const destination = parts[2] || "SEA";
const departure = parts[3] || "10:40 AM";
const gate = parts[4] || "B12";
const weather = parts[5] || "58° · Light rain";
const essentials = (parts[6] || "Passport,Headphones,Charger").split(",").slice(0, 3);

$render(
  <vstack frame="max" alignment="leading" spacing="13" padding="18" background="#075985">
    <hstack frame="max"><vstack alignment="leading" spacing="2"><text font="title2" weight="bold" color="white">Travel Day</text><text font="caption" color="#7dd3fc">Everything before boarding</text></vstack><spacer/><badge text={flight} color="#38bdf8"/></hstack>
    <hstack frame="max" spacing="12" padding="15" background="#0369a1" corner="15">
      <vstack alignment="leading" spacing="2"><text font="largeTitle" weight="bold" color="white">{origin}</text><text font="caption" color="#7dd3fc">DEPART</text></vstack>
      <spacer/><vstack spacing="5"><icon systemName="airplane" size="28" color="#38bdf8"/><rect frame="92,2" color="#164e63" corner="1"/></vstack><spacer/>
      <vstack alignment="trailing" spacing="2"><text font="largeTitle" weight="bold" color="white">{destination}</text><text font="caption" color="#7dd3fc">ARRIVE</text></vstack>
    </hstack>
    <hstack frame="max" spacing="10">
      <vstack frame="max,82,leading" alignment="leading" spacing="4" padding="11" background="#10253a" corner="12"><text font="caption2" color="#64748b">DEPARTURE</text><text font="headline" color="white">{departure}</text></vstack>
      <vstack frame="max,82,leading" alignment="leading" spacing="4" padding="11" background="#10253a" corner="12"><text font="caption2" color="#64748b">GATE</text><text font="headline" color="white">{gate}</text></vstack>
      <vstack frame="max,82,leading" alignment="leading" spacing="4" padding="11" background="#10253a" corner="12"><text font="caption2" color="#64748b">DESTINATION</text><text font="headline" color="white">{weather}</text></vstack>
    </hstack>
    <vstack frame="max" alignment="leading" spacing="10" padding="13" background="#10253a" corner="14">
      <hstack frame="max"><text font="caption" weight="bold" color="#bae6fd">BEFORE YOU GO</text><spacer/><icon systemName="checklist" size="15" color="#38bdf8"/></hstack>
      {essentials.map(item => <hstack frame="max" spacing="9"><circle frame="12,12" color="#164e63"/><text font="callout" color="#e0f2fe">{item.trim()}</text><spacer/><text font="caption2" color="#38bdf8">PACKED?</text></hstack>)}
    </vstack>
  </vstack>
);
