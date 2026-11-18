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

const fetchSeries = async (seriesList) => {
  let response = [];

  for (let series of seriesList) {
    response.push(JSON.parse(await fetch(API_URL + series)));
  }
  return response;
};

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

const Logo = ({ logoPath }) => {
  return (
    <zstack>
      <image url={logoPath} frame="40,40,trailing" />
      <rect color={colors.secondary} stroke="1" frame="40,40" />
    </zstack>
  );
};

const Entry = ({ info }) => {
  const getNextEpisode = (countdown) => `s${countdown.season}e${countdown.episode}`;

  const nextEpisodeRemaining = (countdown) => {
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

const seriesJson = await fetchSeries(series);

$render(
  <zstack background={colors.primary}>
    <vstack padding="10,10,10,20" frame="max,top">
      {seriesJson?.map((series) => (
        <Entry info={series.tvShow} />
      ))}
    </vstack>
  </zstack>,
);
