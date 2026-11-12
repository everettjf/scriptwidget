//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Now Playing: a music card. Replace `track` and `queue` with your own.
//

const size = $getenv("widget-size");
const track = { title: "Midnight Drive", artist: "Neon Coast", album: "Afterglow", elapsed: 94, length: 236 };
const queue = [["Ocean Avenue", "Neon Coast"], ["Paper Planes", "Lumen"], ["Static Bloom", "Velvet Hours"]];
const art = $gradient({ type: "linear", colors: ["#FF5F6D", "#7B2FF7"], startPoint: "topLeading", endPoint: "bottomTrailing" });
const backdrop = $gradient({ type: "linear", colors: ["#2A1B3D", "#120E1E"], startPoint: "top", endPoint: "bottom" });
const clock = (seconds) => `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;

const Artwork = ({ side }) => (
  <zstack frame={`${side},${side}`} background={art} corner={side * 0.14}>
    <icon systemName="music.note" size={Math.round(side * 0.42)} color="white" opacity="0.9" />
  </zstack>
);
const Titles = ({ font }) => (
  <vstack alignment="leading" spacing="2">
    <text font={font} fontWeight="semibold" color="white">{track.title}</text>
    <text font="caption" color="#B9A8D9">{track.artist}</text>
  </vstack>
);
const Progress = () => (
  <vstack spacing="3">
    <progress value={track.elapsed} total={track.length} color="white" trackColor="#4A3B66" />
    <hstack><text font="caption2" color="#B9A8D9">{clock(track.elapsed)}</text><spacer /><text font="caption2" color="#B9A8D9">-{clock(track.length - track.elapsed)}</text></hstack>
  </vstack>
);
const Controls = ({ size: iconSize }) => (
  <hstack spacing={iconSize * 1.4}>
    <icon systemName="backward.fill" size={iconSize} color="white" />
    <icon systemName="pause.fill" size={iconSize * 1.3} color="white" />
    <icon systemName="forward.fill" size={iconSize} color="white" />
  </hstack>
);

if (size === "accessoryCircular") {
  $render(<zstack><ring value={track.elapsed / track.length} thickness="4" frame="max" /><icon systemName="music.note" size="20" /></zstack>);
} else if (size === "accessoryRectangular") {
  $render(
    <vstack alignment="leading" spacing="2" frame="max,leading">
      <text font="headline">{track.title}</text>
      <text font="caption">{track.artist}</text>
      <progress value={track.elapsed} total={track.length} />
    </vstack>
  );
} else if (size === "accessoryInline") {
  $render(<text>♪ {track.title} · {track.artist}</text>);
} else if (size === "small") {
  $render(
    <vstack alignment="leading" spacing="8" padding="14" background={backdrop}>
      <Artwork side={64} />
      <spacer />
      <Titles font="subheadline" />
    </vstack>
  );
} else if (size === "medium") {
  $render(
    <hstack spacing="14" padding="14" background={backdrop}>
      <Artwork side={118} />
      <vstack alignment="leading" spacing="8" frame="max,leading">
        <Titles font="headline" />
        <spacer />
        <Progress />
        <hstack><spacer /><Controls size={16} /><spacer /></hstack>
      </vstack>
    </hstack>
  );
} else {
  const wide = size === "extraLarge";
  const nowPlaying = (
    <vstack alignment="leading" spacing="12" frame="max,leading">
      <hstack spacing="14">
        <Artwork side={wide ? 140 : 96} />
        <vstack alignment="leading" spacing="6" frame="max,leading">
          <text font="caption2" fontWeight="semibold" color="#B9A8D9">NOW PLAYING</text>
          <Titles font="title3" />
          <text font="caption" color="#8D7BB0">{track.album}</text>
        </vstack>
      </hstack>
      <Progress />
      <hstack><spacer /><Controls size={20} /><spacer /></hstack>
    </vstack>
  );
  const upNext = (
    <vstack alignment="leading" spacing="8" frame="max,leading">
      <text font="caption" fontWeight="semibold" color="#B9A8D9">UP NEXT</text>
      {queue.slice(0, wide ? 3 : 2).map(([title, artist]) => (
        <hstack spacing="10">
          <rect frame="28,28" corner="6" color="#3A2C52" />
          <vstack alignment="leading" spacing="0"><text font="subheadline" color="white">{title}</text><text font="caption2" color="#8D7BB0">{artist}</text></vstack>
          <spacer />
        </hstack>
      ))}
    </vstack>
  );
  $render(wide
    ? <hstack alignment="top" spacing="32" padding="24" background={backdrop}>{nowPlaying}{upNext}</hstack>
    : <vstack alignment="leading" spacing="14" padding="16" background={backdrop}>{nowPlaying}<rect color="#3A2C52" frame="max,1" />{upNext}<spacer /></vstack>);
}
