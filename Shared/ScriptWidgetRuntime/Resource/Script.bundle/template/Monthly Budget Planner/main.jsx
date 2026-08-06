// Large widget. widget-param: budget,spent,housing,food,fun
const values = ($getenv("widget-param") || "4200,2675,1450,620,280").split(",").map(Number);
const budget = values[0] || 4200;
const spent = Math.max(0, values[1] || 0);
const remaining = Math.max(0, budget - spent);
const categories = [
  { name: "Housing", value: values[2] || 0, cap: budget * 0.4, color: "#818cf8" },
  { name: "Food", value: values[3] || 0, cap: budget * 0.2, color: "#34d399" },
  { name: "Flexible", value: values[4] || 0, cap: budget * 0.15, color: "#fb7185" }
];
const money = value => `$${Math.round(value).toLocaleString()}`;

const Category = ({ item }) => (
  <vstack frame="max" alignment="leading" spacing="5">
    <hstack frame="max"><text font="callout" color="#e2e8f0">{item.name}</text><spacer/><text font="caption" color="#94a3b8">{money(item.value)} / {money(item.cap)}</text></hstack>
    <progress value={item.value} total={item.cap} thickness="7" color={item.color} trackColor="#1e293b"/>
  </vstack>
);

$render(
  <vstack frame="max" alignment="leading" spacing="13" padding="18" background="#065f46">
    <hstack frame="max"><vstack alignment="leading" spacing="2"><text font="title2" weight="bold" color="white">Monthly Budget</text><date date="now" style="date" font="caption" color="#6ee7b7"/></vstack><spacer/><icon systemName="chart.pie.fill" size="26" color="#2dd4bf"/></hstack>
    <hstack frame="max" spacing="12">
      <vstack frame="max,90,leading" alignment="leading" spacing="4" padding="12" background="#047857" corner="14"><text font="caption" color="#a7f3d0">REMAINING</text><text font="title2" weight="bold" color="white">{money(remaining)}</text><text font="caption2" color="#d1fae5">{Math.round(remaining / budget * 100)}% available</text></vstack>
      <vstack frame="max,90,leading" alignment="leading" spacing="4" padding="12" background="#047857" corner="14"><text font="caption" color="#d1fae5">SPENT</text><text font="title2" weight="bold" color="#f8fafc">{money(spent)}</text><text font="caption2" color="#d1fae5">of {money(budget)}</text></vstack>
    </hstack>
    <vstack frame="max" alignment="leading" spacing="12" padding="14" background="#064e3b" corner="14">
      <hstack frame="max"><text font="caption" weight="bold" color="#99f6e4">CATEGORY GUARDRAILS</text><spacer/><badge text={`${Math.round(spent / budget * 100)}% USED`} color="#2dd4bf"/></hstack>
      {categories.map(item => <Category item={item}/>)}
    </vstack>
  </vstack>
);
