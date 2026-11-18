// widget-param: your affirmation (optional)
const words=($getenv("widget-param")||"I have everything I need for today.").trim();
$render(<vstack frame="max" alignment="leading" spacing="8" padding="14" background="#7c3aed"><icon systemName="quote.opening" size="22" color="#ede9fe"/><text frame="max,leading" font="headline" weight="bold" color="white">{words}</text><text font="caption" color="#f5f3ff">DAILY AFFIRMATION</text></vstack>);
