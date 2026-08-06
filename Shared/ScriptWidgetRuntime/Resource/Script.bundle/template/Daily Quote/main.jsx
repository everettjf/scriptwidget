//
// ScriptWidget
// https://xnu.app/scriptwidget
//
// Daily Quote (zenquotes.io)
//

const url = "https://zenquotes.io/api/today";
const result = await fetch(url);
const data = JSON.parse(result);
const quote = data && data.length ? data[0] : { q: "Stay inspired", a: "ScriptWidget" };

$render(
  <vstack frame="max" background="#b45309">
    <text font="caption" color="#fde68a">Daily Quote</text>
    <text font="caption" color="#fff7ed">"{quote.q}"</text>
    <text font="caption2" color="#fed7aa">- {quote.a}</text>
  </vstack>
);
