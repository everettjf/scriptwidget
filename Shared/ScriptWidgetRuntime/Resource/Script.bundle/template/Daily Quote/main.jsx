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
// This template has no widget.json. In a package that has one, fetch only works when
// widget.json declares the "network" permission and lists this host in "networkDomains".
const url = "https://zenquotes.io/api/today";
const result = await fetch(url);
const data = JSON.parse(result);
// The answer is a list with one quote: `q` is the text and `a` the author.
// The fallback is used when the list is empty.
const quote = data && data.length ? data[0] : { q: "Stay inspired", a: "ScriptWidget" };

// frame="max" makes the stack fill the whole widget.
$render(
  <vstack frame="max" background="#b45309">
    <text font="caption" color="#fde68a">
      Daily Quote
    </text>
    <text font="caption" color="#fff7ed">
      "{quote.q}"
    </text>
    <text font="caption2" color="#fed7aa">
      - {quote.a}
    </text>
  </vstack>,
);
