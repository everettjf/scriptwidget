// Large widget. widget-param: Focus task|09:00 Stand-up,11:30 Deep work,15:00 Review|Email Alex,Book dentist,Walk 20 min
const parts = ($getenv("widget-param") || "Ship the weekly update|09:00 Stand-up,11:30 Deep work,15:00 Review|Reply to Sam,Book dentist,Walk 20 min").split("|");
const focus = (parts[0] || "Choose one meaningful outcome").trim();
const schedule = (parts[1] || "").split(",").filter(Boolean).slice(0, 3);
const tasks = (parts[2] || "").split(",").filter(Boolean).slice(0, 3);
const now = new Date();
const progress = (now.getHours() * 60 + now.getMinutes()) / 1440;

const Row = ({ text, index }) => (
  <hstack frame="max" spacing="9">
    <circle frame="7,7" color={index === 0 ? "#60a5fa" : "#334155"}/>
    <text font="caption" color={index === 0 ? "#f8fafc" : "#cbd5e1"}>{text.trim()}</text>
    <spacer/>
  </hstack>
);

$render(
  <vstack frame="max" alignment="leading" spacing="12" padding="18" background="#172554">
    <hstack frame="max">
      <vstack alignment="leading" spacing="2"><text font="title2" weight="bold" color="white">Today</text><date date="now" style="date" font="caption" color="#94a3b8"/></vstack>
      <spacer/><badge text="COMMAND CENTER" color="#93c5fd"/>
    </hstack>
    <vstack frame="max,76,leading" alignment="leading" spacing="5" padding="12" background="#1d4ed8" corner="14">
      <text font="caption2" weight="bold" color="#93c5fd">PRIMARY OUTCOME</text>
      <text font="title3" weight="bold" color="white">{focus}</text>
      <progress value={progress} total="1" thickness="5" color="#60a5fa" trackColor="#1e3a8a"/>
    </vstack>
    <hstack frame="max" spacing="12">
      <vstack frame="max,146,topLeading" alignment="leading" spacing="9" padding="12" background="#111827" corner="14">
        <hstack frame="max"><text font="caption" weight="bold" color="#a5b4fc">SCHEDULE</text><spacer/><icon systemName="clock.fill" size="14" color="#818cf8"/></hstack>
        {schedule.map((item, i) => <Row text={item} index={i}/>)}
      </vstack>
      <vstack frame="max,146,topLeading" alignment="leading" spacing="9" padding="12" background="#111827" corner="14">
        <hstack frame="max"><text font="caption" weight="bold" color="#6ee7b7">QUICK TASKS</text><spacer/><icon systemName="checkmark.circle.fill" size="14" color="#34d399"/></hstack>
        {tasks.map((item, i) => <Row text={item} index={i}/>)}
      </vstack>
    </hstack>
  </vstack>
);
