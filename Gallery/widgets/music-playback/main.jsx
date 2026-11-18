// iOS Music app only. Allow Music access in ScriptWidget Settings.
// The browser uses editable samples. No queue changes or playback actions.
const family = $getenv("widget-size"), accessory = family.startsWith("accessory");
const dark = $device.isdarkmode(), compact = family === "small";
const background = accessory ? "clear" : dark ? "#262235" : "#f5f1fc";
const primary = accessory ? "primary" : dark ? "#f4ecff" : "#3e3159";
const secondary = accessory ? "secondary" : dark ? "#bfb1d4" : "#796b90";
let playback = null, notice = "Allow Music access", detail = "Open Music access in ScriptWidget Settings.";
try {
  if (!$music.isAvailable()) { notice = "Music unavailable"; detail = "This platform cannot read the system Music player."; }
  else if ($music.authorizationStatus() === "authorized") playback = await $music.current();
} catch (error) {
  const permission = String(error).includes("music_permission");
  notice = permission ? "Allow Music access" : "Unable to refresh";
  detail = permission ? "Review Music access in ScriptWidget Settings." : "Open ScriptWidget and refresh this widget.";
}
const states = {playing:"Playing",paused:"Paused",stopped:"Stopped",interrupted:"Interrupted",seeking:"Seeking",unknown:"Playback snapshot"};
const status = playback ? states[playback.state] : notice;
const title = playback ? playback.title || (playback.state === "stopped" ? "No current track" : "Track details unavailable") : notice;
const subtitle = playback ? [playback.artist, playback.album].filter(Boolean).join(" · ") || "Music app" : detail;
const symbol = playback?.state === "paused" ? "pause.fill" : playback?.state === "playing" ? "waveform" : "music.note";
const time = seconds => `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2,"0")}`;
const progress = playback?.duration !== null && playback?.duration > 0 && playback?.position !== null ? Math.min(1,playback.position / playback.duration) : null;
if (family === "accessoryInline") {
  $render(<text>{`${status} · ${title}`}</text>);
} else if (family === "accessoryCircular") {
  $render(<vstack spacing="2"><image systemName={symbol}/><text font="caption2">{playback ? status : "Setup"}</text></vstack>);
} else if (family === "accessoryRectangular") {
  $render(<vstack alignment="leading" spacing="2"><text font="headline">{title}</text><text font="caption2">{`${status} · ${playback ? playback.artist || "Music app" : "Open ScriptWidget"}`}</text></vstack>);
} else {
  $render(<vstack frame="max" alignment="leading" spacing={compact || family === "medium" ? "8" : "16"} padding="16" background={background}>
    <hstack spacing="8"><image systemName={symbol} font="title2" color={primary}/><text font="caption" color={secondary}>{compact && !playback ? "Setup" : status}</text><spacer/><text font="caption2" color={secondary}>Music</text></hstack>
    <spacer/>
    <text font={compact ? "subheadline" : "title2"} fontWeight="semibold" color={primary}>{title}</text>
    <text font="caption" color={secondary}>{subtitle}</text>
    {progress !== null && <vstack spacing="4"><progress value={String(progress)} color={primary}/><hstack><text font="caption2" color={secondary}>{time(playback.position)}</text><spacer/><text font="caption2" color={secondary}>{time(playback.duration)}</text></hstack></vstack>}
    {!compact && family !== "medium" && <><spacer/><text font="caption2" color={secondary}>A playback snapshot. Refresh to update.</text></>}
  </vstack>);
}
