// widget-param: focus minutes (optional)
const minutes = Math.max(5, Number($getenv("widget-param")) || 25);
$render(<vstack frame="max" spacing="10" padding="14" background="#be123c"><hstack frame="max"><icon systemName="timer" size="20" color="#ffe4e6"/><text font="headline" weight="bold" color="white">Focus session</text><spacer/></hstack><spacer/><text font="largeTitle" weight="bold" color="white">{minutes}:00</text><text font="caption" color="#ffe4e6">One task. No distractions.</text><spacer/><progress value="0.2" total="1" color="#fda4af"/></vstack>);
