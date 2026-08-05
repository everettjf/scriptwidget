// widget-param: Passport,Charger,Headphones (optional)
const items=($getenv("widget-param")||"Passport,Charger,Headphones").split(",").slice(0,3);
$render(<vstack frame="max" alignment="leading" spacing="7" padding="14" background="#0c4a6e"><hstack frame="max"><text font="headline" weight="bold" color="white">Ready to go</text><spacer/><icon systemName="suitcase.rolling.fill" size="21" color="#7dd3fc"/></hstack>{items.map(item=><hstack spacing="7"><icon systemName="circle" size="13" color="#bae6fd"/><text font="callout" color="white">{item.trim()}</text></hstack>)}</vstack>);
