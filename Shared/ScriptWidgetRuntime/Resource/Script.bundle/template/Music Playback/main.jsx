// iOS Music app only. Allow Music access in ScriptWidget Settings.
// The browser uses editable samples. No queue changes or playback actions.
// Shows what the system music player is playing: state, title, artist and position.
// Try changing the colors, or the texts in `states`.
// $music runs on iPhone and iPad, and on Android (the active media session of any app);
// not on Mac, Windows or Linux. widget.json must declare the permission "music".

// $getenv("widget-size") is the size being drawn: "small", "medium", "large",
// "extraLarge", or a Lock Screen size whose name starts with "accessory".
const family = $getenv("widget-size"),
  accessory = family.startsWith("accessory");
// $device.isdarkmode() is true when the system uses the dark appearance.
const dark = $device.isdarkmode(),
  compact = family === "small";
// Lock Screen sizes get a clear background and the system's own text colors.
const background = accessory ? "clear" : dark ? "#262235" : "#f5f1fc";
const primary = accessory ? "primary" : dark ? "#f4ecff" : "#3e3159";
const secondary = accessory ? "secondary" : dark ? "#bfb1d4" : "#796b90";
// Read the data. Without it, `notice` and `detail` say what to do.
let playback = null,
  notice = "Allow Music access",
  detail = "Open Music access in ScriptWidget Settings.";
try {
  // isAvailable() is false on a system without this API.
  if (!$music.isAvailable()) {
    notice = "Music unavailable";
    detail = "This platform cannot read the system Music player.";
  } else if ($music.authorizationStatus() === "authorized") playback = await $music.current();
} catch (error) {
  // A failed call throws an error whose text contains a code such as music_permission.
  const permission = String(error).includes("music_permission");
  notice = permission ? "Allow Music access" : "Unable to refresh";
  detail = permission
    ? "Review Music access in ScriptWidget Settings."
    : "Open ScriptWidget and refresh this widget.";
}
// A text for each playback state.
const states = {
  playing: "Playing",
  paused: "Paused",
  stopped: "Stopped",
  interrupted: "Interrupted",
  seeking: "Seeking",
  unknown: "Playback snapshot",
};
// The texts to show, with a fallback when a detail is missing.
const status = playback ? states[playback.state] : notice;
const title = playback
  ? playback.title ||
    (playback.state === "stopped" ? "No current track" : "Track details unavailable")
  : notice;
const subtitle = playback
  ? [playback.artist, playback.album].filter(Boolean).join(" · ") || "Music app"
  : detail;
const symbol =
  playback?.state === "paused"
    ? "pause.fill"
    : playback?.state === "playing"
      ? "waveform"
      : "music.note";
// Seconds as m:ss, so 94 becomes "1:34".
const time = (seconds) =>
  `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, "0")}`;
// The played share of the track, 0 to 1; null when position or duration is unknown.
const progress =
  playback?.duration !== null && playback?.duration > 0 && playback?.position !== null
    ? Math.min(1, playback.position / playback.duration)
    : null;
if (family === "accessoryInline") {
  // Lock Screen, inline: one line of text.
  $render(<text>{`${status} · ${title}`}</text>);
} else if (family === "accessoryCircular") {
  // Lock Screen, circular: a symbol and the state.
  $render(
    <vstack spacing="2">
      <image systemName={symbol} />
      <text font="caption2">{playback ? status : "Setup"}</text>
    </vstack>,
  );
} else if (family === "accessoryRectangular") {
  // Lock Screen, rectangular: title, state and artist.
  $render(
    <vstack alignment="leading" spacing="2">
      <text font="headline">{title}</text>
      <text font="caption2">{`${status} · ${playback ? playback.artist || "Music app" : "Open ScriptWidget"}`}</text>
    </vstack>,
  );
} else {
  // Home Screen sizes. frame="max" fills the widget; padding is the space around the content.
  $render(
    <vstack
      frame="max"
      alignment="leading"
      spacing={compact || family === "medium" ? "8" : "16"}
      padding="16"
      background={background}
    >
      <hstack spacing="8">
        <image systemName={symbol} font="title2" color={primary} />
        <text font="caption" color={secondary}>
          {compact && !playback ? "Setup" : status}
        </text>
        <spacer />
        <text font="caption2" color={secondary}>
          Music
        </text>
      </hstack>
      <spacer />
      <text font={compact ? "subheadline" : "title2"} fontWeight="semibold" color={primary}>
        {title}
      </text>
      <text font="caption" color={secondary}>
        {subtitle}
      </text>
      {/* The bar and the two times appear only when the position is known. */}
      {progress !== null && (
        <vstack spacing="4">
          <progress value={String(progress)} color={primary} />
          <hstack>
            <text font="caption2" color={secondary}>
              {time(playback.position)}
            </text>
            <spacer />
            <text font="caption2" color={secondary}>
              {time(playback.duration)}
            </text>
          </hstack>
        </vstack>
      )}
      {/* Large sizes add a note. <>…</> groups children without adding a stack. */}
      {!compact && family !== "medium" && (
        <>
          <spacer />
          <text font="caption2" color={secondary}>
            A playback snapshot. Refresh to update.
          </text>
        </>
      )}
    </vstack>,
  );
}
