// Shows when the next episode of each series airs.
// Try your own series by editing the EpisoDate slugs below.
// widget.json declares the API and poster hosts this package uses.

const series = ["the-lord-of-the-rings", "house-of-the-dragon"];
const apiURL = "https://www.episodate.com/api/show-details?q=";
const accent = "#86efac";

// One failed request should not hide the other series.
async function fetchShow(slug) {
  try {
    const show = JSON.parse(await fetch(apiURL + encodeURIComponent(slug)))?.tvShow;
    if (typeof show?.name === "string" && show.name.trim()) return show;
  } catch {
    // Show a readable unavailable state for this series.
  }
  return null;
}

function nextEpisode(countdown) {
  const date = countdown?.air_date;
  if (typeof date !== "string" || !/^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2})?Z?$/.test(date))
    return;
  // EpisoDate gives air dates in GMT.
  const time = new Date(date.replace(" ", "T") + (date.endsWith("Z") ? "" : "Z")).getTime();
  if (!Number.isFinite(time) || time <= Date.now()) return;

  const season = countdown.season;
  const episode = countdown.episode;
  if (!/^\d{1,3}$/.test(String(season)) || !/^\d{1,3}$/.test(String(episode))) return;

  const minutes = Math.ceil((time - Date.now()) / 60000);
  const days = Math.floor(minutes / 1440);
  const hours = Math.floor((minutes % 1440) / 60);
  const remaining = days ? days + "d " + hours + "h" : hours ? hours + "h" : minutes + "m";
  return "s" + season + "e" + episode + " · " + remaining + " left";
}

const Entry = ({ show, slug }) => {
  const name = show?.name ?? slug.replace(/-/g, " ");
  const schedule = show
    ? (nextEpisode(show.countdown) ?? (show.status === "Ended" ? "Ended" : "No date announced"))
    : "Schedule unavailable";
  // Use only the provider's HTTPS poster paths. The browser samples omit posters.
  const image =
    typeof show?.image_path === "string" &&
    /^https:\/\/static\.episodate\.com\/images\/tv-show\/full\/\d+\.jpg$/.test(show.image_path)
      ? show.image_path
      : null;
  return (
    <hstack frame="max,leading" spacing="6">
      {image ? (
        <image url={image} frame="30,36" />
      ) : (
        <icon systemName="tv.fill" size="19" color={accent} frame="30,36" />
      )}
      <vstack alignment="leading" spacing="2">
        <text font="caption" color="white">
          {name}
        </text>
        <text font="caption2" color={accent}>
          {schedule}
        </text>
      </vstack>
    </hstack>
  );
};

// Await the response from each series before drawing the rows.
const shows = [];
for (const slug of series) {
  shows.push(await fetchShow(slug));
}

$render(
  <vstack frame="max" alignment="leading" spacing="5" padding="10" background="#080808">
    {shows.map((show, index) => (
      <Entry show={show} slug={series[index]} />
    ))}
    <link url="https://www.episodate.com/">
      <text font="caption2" color={accent}>
        Data by EpisoDate
      </text>
    </link>
  </vstack>,
);
