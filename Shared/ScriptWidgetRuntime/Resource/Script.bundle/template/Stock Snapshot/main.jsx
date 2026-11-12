//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Stock Snapshot (stooq.com)
// widget-param: symbol, e.g. "aapl.us"
//

const symbol = ($getenv("widget-param") || "aapl.us").trim().toLowerCase();
const url = `https://stooq.com/q/l/?s=${symbol}&i=d`;
const result = await fetch(url);
const lines = result.trim().split("\n");
let closeValue = "-";
let openValue = "-";
let dateValue = "-";

if (lines.length > 1) {
  const cols = lines[1].split(",");
  dateValue = cols[1] || "-";
  openValue = cols[2] || "-";
  closeValue = cols[5] || "-";
}

let change = "-";
if (openValue !== "-" && closeValue !== "-") {
  const openNum = parseFloat(openValue);
  const closeNum = parseFloat(closeValue);
  if (!Number.isNaN(openNum) && !Number.isNaN(closeNum)) {
    const diff = closeNum - openNum;
    const pct = (diff / openNum) * 100;
    change = `${diff.toFixed(2)} (${pct.toFixed(2)}%)`;
  }
}

$render(
  <vstack frame="max" background="#0f172a">
    <text font="caption" color="#94a3b8">Stock Snapshot</text>
    <text font="title3" color="#e2e8f0">{symbol.toUpperCase()}</text>
    <text font="caption" color="#94a3b8">Close: {closeValue}</text>
    <text font="caption" color="#94a3b8">Change: {change}</text>
    <text font="caption2" color="#64748b">Date: {dateValue}</text>
  </vstack>
);
