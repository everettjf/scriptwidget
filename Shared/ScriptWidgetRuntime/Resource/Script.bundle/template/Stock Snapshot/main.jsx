//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Stock Snapshot (stooq.com)
// widget-param: symbol, e.g. "aapl.us"
//
// Shows how to download text with fetch and pick values out of CSV.
// Try another symbol in the widget parameter.
//

// $getenv("widget-param") is the parameter text set for this widget; when it is empty
// the symbol is "aapl.us".
const symbol = ($getenv("widget-param") || "aapl.us").trim().toLowerCase();
const url = `https://stooq.com/q/l/?s=${symbol}&i=d`;
// fetch returns the response body as a string. A package with a widget.json must declare
// the "network" permission and the host in networkDomains for this call to work.
const result = await fetch(url);
// The answer is CSV: one row per line, values separated by commas.
const lines = result.trim().split("\n");
let closeValue = "-";
let openValue = "-";
let dateValue = "-";

// The code expects a line of column names first and reads the values from the second
// line. With fewer lines, every value stays "-".
if (lines.length > 1) {
  const cols = lines[1].split(",");
  dateValue = cols[1] || "-";
  openValue = cols[2] || "-";
  closeValue = cols[5] || "-";
}

// The change from open to close, as an amount and as a percentage of the open.
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

// frame="max" makes the stack, and with it the background, fill the widget.
$render(
  <vstack frame="max" background="#0f172a">
    <text font="caption" color="#94a3b8">
      Stock Snapshot
    </text>
    <text font="title3" color="#e2e8f0">
      {symbol.toUpperCase()}
    </text>
    <text font="caption" color="#94a3b8">
      Close: {closeValue}
    </text>
    <text font="caption" color="#94a3b8">
      Change: {change}
    </text>
    <text font="caption2" color="#64748b">
      Date: {dateValue}
    </text>
  </vstack>,
);
