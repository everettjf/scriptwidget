// Large widget. widget-param: Family name|events comma-separated|chores comma-separated|dinner
const parts = ($getenv("widget-param") || "The Parkers|08:15 School drop-off,17:30 Soccer practice,19:00 Call Grandma|Mia · Feed Mochi,Noah · Recycling,All · Tidy kitchen|Taco bowls · 18:30").split("|");
const family = (parts[0] || "Our Family").trim();
const events = (parts[1] || "").split(",").filter(Boolean).slice(0, 3);
const chores = (parts[2] || "").split(",").filter(Boolean).slice(0, 3);
const dinner = (parts[3] || "Plan dinner together").trim();
const colors = ["#fb7185", "#fbbf24", "#60a5fa"];

const Event = ({ text, index }) => (
    <hstack frame="max" spacing="9"><rect frame="4,28" color={colors[index]} corner="2"/><text font="caption" color="#f8fafc">{text.trim()}</text><spacer/></hstack>
);

$render(
  <vstack frame="max" alignment="leading" spacing="12" padding="18" background="#831843">
    <hstack frame="max"><vstack alignment="leading" spacing="2"><text font="title2" weight="bold" color="white">{family}</text><text font="caption" color="#a1a1aa">Home at a glance</text></vstack><spacer/><icon systemName="house.fill" size="26" color="#fb7185"/></hstack>
    <hstack frame="max" spacing="12">
      <vstack frame="max,154,topLeading" alignment="leading" spacing="9" padding="13" background="#9d174d" corner="14">
        <hstack frame="max"><text font="caption" weight="bold" color="#fda4af">TODAY</text><spacer/><date date="now" style="date" font="caption2" color="#a1a1aa"/></hstack>
        {events.map((item, i) => <Event text={item} index={i}/>)}
      </vstack>
      <vstack frame="max,154,topLeading" alignment="leading" spacing="9" padding="13" background="#9d174d" corner="14">
        <hstack frame="max"><text font="caption" weight="bold" color="#fde68a">CHORES</text><spacer/><badge text={`${chores.length} LEFT`} color="#fbbf24"/></hstack>
        {chores.map(item => <hstack frame="max" spacing="8"><circle frame="12,12" color="#3f3f46"/><text font="caption" color="#e4e4e7">{item.trim()}</text><spacer/></hstack>)}
      </vstack>
    </hstack>
    <hstack frame="max,72,leading" spacing="12" padding="13" background="#be185d" corner="14"><icon systemName="fork.knife" size="22" color="#fce7f3"/><vstack alignment="leading" spacing="2"><text font="caption2" weight="bold" color="#fce7f3">DINNER PLAN</text><text font="headline" color="white">{dinner}</text></vstack><spacer/></hstack>
  </vstack>
);
