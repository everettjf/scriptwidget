//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Currency Pulse (open.er-api.com)
// widget-param: base currency (optional)
//
// Shows what one unit of the base currency is worth in three others, read from a web API.
// Try changing the three currency codes in the <stat> elements.
//

// $getenv("widget-param") is the parameter set for this widget; "USD" is used when it is empty.
const base = ($getenv("widget-param").trim() || "USD").toUpperCase();
const validBase = /^[A-Z]{3}$/.test(base);
// Read the data from open.er-api.com.
// Here fetch returns the response body as text, so it is parsed with JSON.parse.
// widget.json lists the exact allowed host.
let rates;
if (validBase) {
  try {
    const data = JSON.parse(await fetch(`https://open.er-api.com/v6/latest/${base}`));
    // `rates` maps a currency code to its rate, for example { EUR: 0.92, … }.
    if (
      data?.result === "success" &&
      ["CNY", "EUR", "JPY"].some(
        (code) => Number.isFinite(data.rates?.[code]) && data.rates[code] > 0,
      )
    )
      rates = data.rates;
  } catch {
    // Show a readable state if the provider cannot be reached.
  }
}
const formatRate = (value) => (Number.isFinite(value) && value > 0 ? value.toFixed(2) : "-");

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max" background="#1e3a8a">
    <text font="caption" color="#bfdbfe">
      Currency Pulse
    </text>
    <text font="title3" color="#e2e8f0">
      {validBase ? `Base: ${base}` : "Invalid currency code"}
    </text>
    {rates ? (
      <hstack spacing="8">
        {/* <stat> shows a title and a value. A missing rate is shown with a dash. */}
        <stat title="CNY" value={formatRate(rates.CNY)} color="#bae6fd" mutedColor="#bfdbfe" />
        <stat title="EUR" value={formatRate(rates.EUR)} color="#86efac" mutedColor="#bfdbfe" />
        <stat title="JPY" value={formatRate(rates.JPY)} color="#fcd34d" mutedColor="#bfdbfe" />
      </hstack>
    ) : (
      <text font="caption" color="#e2e8f0">
        Rates unavailable
      </text>
    )}
    <link url="https://www.exchangerate-api.com">
      <text font="caption2" color="#bfdbfe">
        Rates by ExchangeRate-API
      </text>
    </link>
  </vstack>,
);
