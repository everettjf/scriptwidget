// widget-param: a short intention (optional)
const note = ($getenv("widget-param") || "Pause, breathe, and notice").trim();
$render(<vstack frame="max" spacing="10" padding="14" background="#312e81"><hstack frame="max"><text font="headline" weight="bold" color="white">How are you?</text><spacer/><icon systemName="face.smiling" size="22" color="#c4b5fd"/></hstack><spacer/><hstack spacing="10"><text font="title">😌</text><text font="title">🙂</text><text font="title">😊</text><text font="title">🤩</text></hstack><spacer/><text font="caption" color="#ddd6fe">{note}</text></vstack>);
