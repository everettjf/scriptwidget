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
const symbol = ($getenv("widget-param").trim() || "aapl.us").toLowerCase();
const validSymbol = /^[a-z0-9^][a-z0-9.^_-]{0,19}$/.test(symbol);

// A quote can have a header or start directly with the data row.
function parseQuote(csv) {
  const rows = csv
    .trim()
    .split(/\r?\n/)
    .map((line) => line.split(",").map((cell) => cell.trim()));
  const header = rows[0].map((name) => name.toLowerCase());
  const hasHeader = header[0] === "symbol";
  const row = rows[hasHeader ? 1 : 0];
  if (!row || row[0].toLowerCase() !== symbol) return;
  // The headerless feed can include a time column just after the date.
  const offset = /^\d{2}:\d{2}/.test(row[2] ?? "") ? 1 : 0;
  const date = row[hasHeader ? header.indexOf("date") : 1];
  const open = Number(row[hasHeader ? header.indexOf("open") : 2 + offset]);
  const close = Number(row[hasHeader ? header.indexOf("close") : 5 + offset]);
  if (
    !/^\d{4}-\d{2}-\d{2}$/.test(date ?? "") ||
    !Number.isFinite(open) ||
    !Number.isFinite(close) ||
    open <= 0 ||
    close <= 0
  )
    return;
  return { date, open, close };
}

let quote;
if (validSymbol) {
  // widget.json declares the network permission and this exact host.
  try {
    quote = parseQuote(await fetch(`https://stooq.com/q/l/?s=${encodeURIComponent(symbol)}&i=d`));
  } catch {
    // An unavailable quote is never replaced with a fabricated price.
  }
}

// The change from open to close, as an amount and as a percentage of the open.
const difference = quote ? quote.close - quote.open : 0;
const change = quote
  ? `${difference.toFixed(2)} (${((difference / quote.open) * 100).toFixed(2)}%)`
  : "-";

// frame="max" makes the stack, and with it the background, fill the widget.
$render(
  <vstack frame="max" background="#0f172a">
    <text font="caption" color="#94a3b8">
      Stock Snapshot
    </text>
    <text font="title3" color="#e2e8f0">
      {validSymbol ? symbol.toUpperCase() : "Invalid symbol"}
    </text>
    {quote ? (
      <>
        <text font="caption" color="#cbd5e1">
          Close: {quote.close.toFixed(2)}
        </text>
        <text font="caption" color="#94a3b8">
          Change: {change}
        </text>
        <text font="caption2" color="#a4b3c7">
          Date: {quote.date}
        </text>
      </>
    ) : (
      <text font="caption" color="#cbd5e1">
        Quote unavailable
      </text>
    )}
  </vstack>,
);
