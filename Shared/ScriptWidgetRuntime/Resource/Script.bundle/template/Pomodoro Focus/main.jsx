// widget-param: focus minutes (optional)
const minutes = Math.max(5, Number($getenv("widget-param")) || 25);
$render(<vstack frame="max" spacing="10" padding="14" background="#3f1d2e"><hstack frame="max"><icon systemName="timer" size="20" color="#fb7185"/><text font="headline" weight="bold" color="white">Focus session</text><spacer/></hstack><spacer/><text font="largeTitle" weight="bold" color="#fda4af">{minutes}:00</text><text font="caption" color="#fecdd3">One task. No distractions.</text><spacer/><progress value="0.2" total="1" color="#fb7185"/></vstack>);
