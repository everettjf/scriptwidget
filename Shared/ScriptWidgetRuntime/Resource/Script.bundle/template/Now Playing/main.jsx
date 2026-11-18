//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Now Playing: a music card. Replace `track` and `queue` with your own.
//
// The track is sample data: this card does not read your music player, and the three
// control icons are pictures, not buttons. Try other colors in the two gradients.

// $getenv("widget-size") is the size being drawn, such as "small" or "accessoryInline".
const size = $getenv("widget-size");
// `elapsed` and `length` are in seconds.
const track = {
  title: "Midnight Drive",
  artist: "Neon Coast",
  album: "Afterglow",
  elapsed: 94,
  length: 236,
};
const queue = [
  ["Ocean Avenue", "Neon Coast"],
  ["Paper Planes", "Lumen"],
  ["Static Bloom", "Velvet Hours"],
];
// $gradient(…) makes a background that blends colors, here from corner to corner.
const art = $gradient({
  type: "linear",
  colors: ["#FF5F6D", "#7B2FF7"],
  startPoint: "topLeading",
  endPoint: "bottomTrailing",
});
const backdrop = $gradient({
  type: "linear",
  colors: ["#2A1B3D", "#120E1E"],
  startPoint: "top",
  endPoint: "bottom",
});
// Seconds as m:ss, so 94 becomes "1:34".
const clock = (seconds) => `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;

// The cover: a gradient square with a note. `side` is its size in points.
const Artwork = ({ side }) => (
  <zstack frame={`${side},${side}`} background={art} corner={side * 0.14}>
    <icon systemName="music.note" size={Math.round(side * 0.42)} color="white" opacity="0.9" />
  </zstack>
);
// Title and artist.
const Titles = ({ font }) => (
  <vstack alignment="leading" spacing="2">
    <text font={font} fontWeight="semibold" color="white">
      {track.title}
    </text>
    <text font="caption" color="#B9A8D9">
      {track.artist}
    </text>
  </vstack>
);
// A progress bar with the time played and the time left.
const Progress = () => (
  <vstack spacing="3">
    <progress value={track.elapsed} total={track.length} color="white" trackColor="#4A3B66" />
    <hstack>
      <text font="caption2" color="#B9A8D9">
        {clock(track.elapsed)}
      </text>
      <spacer />
      <text font="caption2" color="#B9A8D9">
        -{clock(track.length - track.elapsed)}
      </text>
    </hstack>
  </vstack>
);
// Previous, pause and next icons.
const Controls = ({ size: iconSize }) => (
  <hstack spacing={iconSize * 1.4}>
    <icon systemName="backward.fill" size={iconSize} color="white" />
    <icon systemName="pause.fill" size={iconSize * 1.3} color="white" />
    <icon systemName="forward.fill" size={iconSize} color="white" />
  </hstack>
);

// Choose a layout for the widget size.
if (size === "accessoryCircular") {
  // Lock Screen, circular: a ring that shows how far the track is.
  $render(
    <zstack>
      <ring value={track.elapsed / track.length} thickness="4" frame="max" />
      <icon systemName="music.note" size="20" />
    </zstack>,
  );
} else if (size === "accessoryRectangular") {
  // Lock Screen, rectangular: title, artist and a progress bar.
  $render(
    <vstack alignment="leading" spacing="2" frame="max,leading">
      <text font="headline">{track.title}</text>
      <text font="caption">{track.artist}</text>
      <progress value={track.elapsed} total={track.length} />
    </vstack>,
  );
} else if (size === "accessoryInline") {
  // Lock Screen, inline: one line of text.
  $render(
    <text>
      ♪ {track.title} · {track.artist}
    </text>,
  );
} else if (size === "small") {
  // Small widget: cover, title and artist.
  $render(
    <vstack alignment="leading" spacing="8" padding="14" background={backdrop}>
      <Artwork side={64} />
      <spacer />
      <Titles font="subheadline" />
    </vstack>,
  );
} else if (size === "medium") {
  // Medium widget: the cover on the left; titles, progress and controls on the right.
  $render(
    <hstack spacing="14" padding="14" background={backdrop}>
      <Artwork side={118} />
      <vstack alignment="leading" spacing="8" frame="max,leading">
        <Titles font="headline" />
        <spacer />
        <Progress />
        <hstack>
          <spacer />
          <Controls size={16} />
          <spacer />
        </hstack>
      </vstack>
    </hstack>,
  );
} else {
  // Large widget: the track above the queue. Extra large widget: side by side.
  // JSX can be kept in a variable and placed later with {nowPlaying}.
  const wide = size === "extraLarge";
  const nowPlaying = (
    <vstack alignment="leading" spacing="12" frame="max,leading">
      <hstack spacing="14">
        <Artwork side={wide ? 140 : 96} />
        <vstack alignment="leading" spacing="6" frame="max,leading">
          <text font="caption2" fontWeight="semibold" color="#B9A8D9">
            NOW PLAYING
          </text>
          <Titles font="title3" />
          <text font="caption" color="#8D7BB0">
            {track.album}
          </text>
        </vstack>
      </hstack>
      <Progress />
      <hstack>
        <spacer />
        <Controls size={20} />
        <spacer />
      </hstack>
    </vstack>
  );
  const upNext = (
    <vstack alignment="leading" spacing="8" frame="max,leading">
      <text font="caption" fontWeight="semibold" color="#B9A8D9">
        UP NEXT
      </text>
      {queue.slice(0, wide ? 3 : 2).map(([title, artist]) => (
        <hstack spacing="10">
          <rect frame="28,28" corner="6" color="#3A2C52" />
          <vstack alignment="leading" spacing="0">
            <text font="subheadline" color="white">
              {title}
            </text>
            <text font="caption2" color="#8D7BB0">
              {artist}
            </text>
          </vstack>
          <spacer />
        </hstack>
      ))}
    </vstack>
  );
  $render(
    wide ? (
      <hstack alignment="top" spacing="32" padding="24" background={backdrop}>
        {nowPlaying}
        {upNext}
      </hstack>
    ) : (
      <vstack alignment="leading" spacing="14" padding="16" background={backdrop}>
        {nowPlaying}
        <rect color="#3A2C52" frame="max,1" />
        {upNext}
        <spacer />
      </vstack>
    ),
  );
}
