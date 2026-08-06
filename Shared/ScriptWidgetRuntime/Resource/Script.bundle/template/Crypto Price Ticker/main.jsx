//
// ScriptWidget
// https://xnu.app/scriptwidget
//
// Crypto Price Ticker (CoinGecko)
// widget-param: coin id, e.g. "bitcoin", "ethereum"
//

const coin = ($getenv("widget-param") || "bitcoin").trim().toLowerCase();
const url = `https://api.coingecko.com/api/v3/simple/price?ids=${coin}&vs_currencies=usd&include_24hr_change=true`;
const result = await fetch(url);
const data = JSON.parse(result);
const info = data[coin] || { usd: 0, usd_24h_change: 0 };

const price = info.usd || 0;
const change = info.usd_24h_change || 0;
const changeColor = change >= 0 ? "#22c55e" : "#ef4444";
const changeLabel = change >= 0 ? "+" + change.toFixed(2) : change.toFixed(2);

$render(
  <vstack frame="max" background="#0f766e">
    <text font="caption" color="#94a3b8">Crypto Ticker</text>
    <text font="title2" color="#e2e8f0">{coin.toUpperCase()}</text>
    <text font="title3" color="#38bdf8">${price.toFixed(2)}</text>
    <text font="caption" color={changeColor}>{changeLabel}% 24h</text>
  </vstack>
);
