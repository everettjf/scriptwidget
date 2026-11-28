//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Daily Quote (zenquotes.io)
//
// Shows the quote of the day, read from a web API. Try changing the colors or fonts.
//

// Read the data.
// Here fetch returns the response body as text, so it is parsed with JSON.parse.
// The network permission and this exact host are declared in widget.json.
const url = "https://zenquotes.io/api/today";
let quote;
try {
  const data = JSON.parse(await fetch(url));
  // The answer is a list with one quote: `q` is the text and `a` the author.
  if (
    Array.isArray(data) &&
    typeof data[0]?.q === "string" &&
    data[0].q.trim() &&
    typeof data[0].a === "string"
  )
    quote = data[0];
} catch {
  // Keep the widget readable while the service is unavailable.
}

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max" padding="8" background="#92400e">
    <text font="caption" color="#fde68a">
      Daily Quote
    </text>
    <text font="caption" color="#fff7ed">
      {quote ? `“${quote.q}”` : "Quote unavailable"}
    </text>
    {quote?.a && (
      <text font="caption2" color="#fed7aa">
        — {quote.a}
      </text>
    )}
    <link url="https://zenquotes.io/">
      <text font="caption2" color="#fed7aa">
        ZenQuotes API
      </text>
    </link>
  </vstack>,
);
