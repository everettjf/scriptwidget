//
// ScriptWidget
// https://xnu.app/scriptwidget
//
// Currency Pulse (open.er-api.com)
// widget-param: base currency (optional)
//

const base = ($getenv("widget-param") || "USD").trim().toUpperCase();
const url = `https://open.er-api.com/v6/latest/${base}`;
const result = await fetch(url);
const data = JSON.parse(result);
const rates = data.rates || {};

$render(
  <vstack frame="max" background="#1d4ed8">
    <text font="caption" color="#94a3b8">Currency Pulse</text>
    <text font="title3" color="#e2e8f0">Base: {base}</text>
    <hstack spacing="12">
      <stat title="CNY" value={rates.CNY ? rates.CNY.toFixed(2) : "-"} subtitle="" color="#38bdf8" />
      <stat title="EUR" value={rates.EUR ? rates.EUR.toFixed(2) : "-"} subtitle="" color="#22c55e" />
      <stat title="JPY" value={rates.JPY ? rates.JPY.toFixed(2) : "-"} subtitle="" color="#f59e0b" />
    </hstack>
  </vstack>
);
