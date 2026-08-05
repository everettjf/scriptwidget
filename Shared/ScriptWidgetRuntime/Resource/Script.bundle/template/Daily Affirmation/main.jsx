// widget-param: your affirmation (optional)
const words=($getenv("widget-param")||"I have everything I need for today.").trim();
$render(<vstack frame="max" alignment="leading" spacing="8" padding="14" background="#4c1d95"><icon systemName="quote.opening" size="22" color="#d8b4fe"/><spacer/><text font="title3" weight="bold" color="white">{words}</text><spacer/><hstack frame="max"><text font="caption" color="#e9d5ff">DAILY AFFIRMATION</text><spacer/></hstack></vstack>);
