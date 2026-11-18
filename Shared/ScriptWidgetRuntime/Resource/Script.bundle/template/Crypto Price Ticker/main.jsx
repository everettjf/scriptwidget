//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Crypto Price Ticker (CoinGecko)
// widget-param: coin id, e.g. "bitcoin", "ethereum"
//
// Shows the price of one coin in US dollars and its 24-hour change, read from a web API.
// Try another coin id as the default, or another currency in the URL.
//

// $getenv("widget-param") is the parameter set for this widget; "bitcoin" is used when it is
// empty.
const coin = ($getenv("widget-param") || "bitcoin").trim().toLowerCase();
// Read the data from CoinGecko.
// Here fetch returns the response body as text, so it is parsed with JSON.parse.
// This template has no widget.json. In a package that has one, fetch only works when
// widget.json declares the "network" permission and lists this host in "networkDomains".
const url = `https://api.coingecko.com/api/v3/simple/price?ids=${coin}&vs_currencies=usd&include_24hr_change=true`;
const result = await fetch(url);
const data = JSON.parse(result);
// The answer looks like { bitcoin: { usd: 64000, usd_24h_change: -1.2 } }.
// An unknown coin id has no entry, so zeros are shown.
const info = data[coin] || { usd: 0, usd_24h_change: 0 };

const price = info.usd || 0;
const change = info.usd_24h_change || 0;
// Green for a rise and red for a fall; a rise also gets a "+" sign.
const changeColor = change >= 0 ? "#22c55e" : "#ef4444";
const changeLabel = change >= 0 ? "+" + change.toFixed(2) : change.toFixed(2);

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max" background="#0f766e">
    <text font="caption" color="#94a3b8">
      Crypto Ticker
    </text>
    <text font="title2" color="#e2e8f0">
      {coin.toUpperCase()}
    </text>
    <text font="title3" color="#38bdf8">
      ${price.toFixed(2)}
    </text>
    <text font="caption" color={changeColor}>
      {changeLabel}% 24h
    </text>
  </vstack>,
);
