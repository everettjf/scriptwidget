// Shows when the next episode of each of your TV series airs.
// Try your own series: put the names used in episodate.com addresses into `series`.
// The data comes from the episodate.com API, so the widget needs a connection.

const API_URL = "https://episodate.com/api/show-details?q=";

const colors = {
  primary: "#080808",
  secondary: "green",
  text: {
    primary: "white",
    secondary: "green",
  },
};

const series = ["the-lord-of-the-rings", "house-of-the-dragon"];

// Load the details of every series, one request after another. fetch resolves to the
// text of the response, which JSON.parse turns into an object.
const fetchSeries = async (seriesList) => {
  let response = [];

  for (let series of seriesList) {
    response.push(JSON.parse(await fetch(API_URL + series)));
  }
  return response;
};

// The time until `airDate` as text, such as "3d 4h left" or "25 m left".
const getTimeLeft = (airDate) => {
  let res;
  const millis = airDate - Date.now();
  const secondsLeft = millis / 1000;

  const getDays = (seconds) => {
    return Math.round(seconds / (3600 * 24));
  };

  const getHours = (seconds) => {
    return Math.round((seconds % (3600 * 24)) / 3600);
  };

  const getMinutes = (seconds) => {
    return Math.round((seconds % 3600) / 60);
  };

  if (getDays(secondsLeft) > 0) {
    res = getDays(secondsLeft) + "d ";
    res += getHours(secondsLeft) + "h ";
  } else if (getHours(secondsLeft) > 0) {
    res = getHours(secondsLeft) + " h ";
  } else {
    res = getMinutes(secondsLeft) + " m ";
  }

  return res + "left";
};

// The poster of a series with a thin outline. <zstack> stacks its children on each other.
const Logo = ({ logoPath }) => {
  return (
    <zstack>
      <image url={logoPath} frame="40,40,trailing" />
      <rect color={colors.secondary} stroke="1" frame="40,40" />
    </zstack>
  );
};

// One row: poster, name, next episode (such as s2e5) and the time left.
const Entry = ({ info }) => {
  const getNextEpisode = (countdown) => `s${countdown.season}e${countdown.episode}`;

  const nextEpisodeRemaining = (countdown) => {
    // air_date is a UTC time with a space in the middle; this makes it an ISO date.
    const airDate = countdown.air_date.replace(" ", "T") + "Z";

    return getTimeLeft(new Date(airDate));
  };

  return (
    <vstack alignment="top">
      <hstack alignment="top">
        <Logo logoPath={info.image_path} />
        <vstack alignment="top">
          <text font="14" frame="200,15,leading" color={colors.text.primary}>
            {info.name}
          </text>
          {/* `countdown` is null when no further episode is announced. */}
          <hstack>
            <text font="caption2" frame="50,15,leading" color={colors.text.secondary}>
              {info.countdown === null ? "ended" : getNextEpisode(info.countdown)}
            </text>
            <text frame="120,15,trailing" font="caption2" color={colors.text.secondary}>
              {info.countdown === null ? "" : nextEpisodeRemaining(info.countdown)}
            </text>
          </hstack>
        </vstack>
        <spacer />
      </hstack>
    </vstack>
  );
};

// Read the data. `await` waits for all answers before anything is drawn.
const seriesJson = await fetchSeries(series);

// $render draws the widget. frame="max,top" fills it and keeps the rows at the top.
$render(
  <zstack background={colors.primary}>
    <vstack padding="10,10,10,20" frame="max,top">
      {seriesJson?.map((series) => (
        <Entry info={series.tvShow} />
      ))}
    </vstack>
  </zstack>,
);
