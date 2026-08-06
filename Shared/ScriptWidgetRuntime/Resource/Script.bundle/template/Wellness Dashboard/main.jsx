// Large widget. widget-param: sleepHours,waterGlasses,steps,mood
const values = ($getenv("widget-param") || "7.5,6,6840,Calm").split(",");
const sleep = Number(values[0]) || 0;
const water = Number(values[1]) || 0;
const steps = Number(values[2]) || 0;
const mood = (values[3] || "Steady").trim();
const score = Math.round(Math.min(100, sleep / 8 * 35 + water / 8 * 25 + steps / 10000 * 40));

const Metric = ({ icon, title, value, detail, color, progress, total }) => (
  <vstack frame="max,92,leading" alignment="leading" spacing="5" padding="11" background="#172033" corner="13">
    <hstack frame="max"><icon systemName={icon} size="16" color={color}/><spacer/><text font="caption2" color="#94a3b8">{title}</text></hstack>
    <text font="title3" weight="bold" color="white">{value}</text>
    <progress value={progress} total={total} thickness="5" color={color} trackColor="#273449"/>
    <text font="caption2" color="#94a3b8">{detail}</text>
  </vstack>
);

$render(
  <vstack frame="max" alignment="leading" spacing="13" padding="18" background="#312e81">
    <hstack frame="max"><vstack alignment="leading" spacing="2"><text font="title2" weight="bold" color="white">Wellness Today</text><text font="caption" color="#94a3b8">Small choices, steady energy</text></vstack><spacer/><badge text={mood.toUpperCase()} color="#c4b5fd"/></hstack>
    <hstack frame="max" spacing="14" padding="14" background="#5b21b6" corner="15">
      <progress style="circular" frame="76" value={score} total="100" thickness="9" label={`${score}`} color="#a78bfa" trackColor="#49356d"/>
      <vstack alignment="leading" spacing="4"><text font="caption" weight="bold" color="#c4b5fd">DAILY BALANCE</text><text font="title3" weight="bold" color="white">Good momentum</text><text font="caption" color="#ddd6fe">Add one glass and a short walk.</text></vstack>
    </hstack>
    <hstack frame="max" spacing="10">
      <Metric icon="bed.double.fill" title="SLEEP" value={`${sleep}h`} detail="8h target" color="#818cf8" progress={sleep} total="8"/>
      <Metric icon="drop.fill" title="WATER" value={`${water}/8`} detail="glasses" color="#38bdf8" progress={water} total="8"/>
    </hstack>
    <Metric icon="figure.walk" title="MOVEMENT" value={steps.toLocaleString()} detail="10,000 step target" color="#34d399" progress={steps} total="10000"/>
  </vstack>
);
