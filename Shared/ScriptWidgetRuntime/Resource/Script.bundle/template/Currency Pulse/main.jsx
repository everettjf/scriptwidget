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
const base = ($getenv("widget-param") || "USD").trim().toUpperCase();
// Read the data from open.er-api.com.
// Here fetch returns the response body as text, so it is parsed with JSON.parse.
// This template has no widget.json. In a package that has one, fetch only works when
// widget.json declares the "network" permission and lists this host in "networkDomains".
const url = `https://open.er-api.com/v6/latest/${base}`;
const result = await fetch(url);
const data = JSON.parse(result);
// `rates` maps a currency code to its rate, for example { EUR: 0.92, … }.
const rates = data.rates || {};

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max" background="#1d4ed8">
    <text font="caption" color="#94a3b8">
      Currency Pulse
    </text>
    <text font="title3" color="#e2e8f0">
      Base: {base}
    </text>
    <hstack spacing="12">
      {/* <stat> is a block with a title, a value and a subtitle. */}
      {/* "-" is shown for a currency that the answer does not contain. */}
      <stat
        title="CNY"
        value={rates.CNY ? rates.CNY.toFixed(2) : "-"}
        subtitle=""
        color="#38bdf8"
      />
      <stat
        title="EUR"
        value={rates.EUR ? rates.EUR.toFixed(2) : "-"}
        subtitle=""
        color="#22c55e"
      />
      <stat
        title="JPY"
        value={rates.JPY ? rates.JPY.toFixed(2) : "-"}
        subtitle=""
        color="#f59e0b"
      />
    </hstack>
  </vstack>,
);
