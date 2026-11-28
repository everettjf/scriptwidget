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
const coin = ($getenv("widget-param").trim() || "bitcoin").toLowerCase();
const validCoin = /^[a-z0-9][a-z0-9_-]{0,79}$/.test(coin);
// Read the data from CoinGecko.
// Here fetch returns the response body as text, so it is parsed with JSON.parse.
// widget.json lists the exact allowed host. Validate the coin ID before building its query.
let info;
if (validCoin) {
  const url = `https://api.coingecko.com/api/v3/simple/price?ids=${coin}&vs_currencies=usd&include_24hr_change=true`;
  try {
    const data = JSON.parse(await fetch(url))?.[coin];
    if (Number.isFinite(data?.usd) && data.usd >= 0) info = data;
  } catch {
    // An unavailable quote is not a zero price.
  }
}

const change = info?.usd_24h_change;
// Green for a rise and red for a fall; a rise also gets a "+" sign.
const changeColor = change >= 0 ? "#86efac" : "#fecaca";
const changeLabel = Number.isFinite(change)
  ? `${change >= 0 ? "+" : ""}${change.toFixed(2)}% 24h`
  : null;

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max" background="#115e59">
    <text font="caption" color="#ccfbf1">
      Crypto Ticker
    </text>
    <text font="title2" color="#e2e8f0">
      {validCoin ? coin.toUpperCase() : "Invalid coin ID"}
    </text>
    <text font={info ? "title3" : "caption"} color="#a5f3fc">
      {info ? `$${info.usd.toFixed(2)}` : "Price unavailable"}
    </text>
    {info && (
      <text font="caption" color={changeLabel ? changeColor : "#ccfbf1"}>
        {changeLabel ?? "24h change unavailable"}
      </text>
    )}
    <link url="https://www.coingecko.com/en/api">
      <text font="caption2" color="#ccfbf1">
        Powered by CoinGecko
      </text>
    </link>
  </vstack>,
);
