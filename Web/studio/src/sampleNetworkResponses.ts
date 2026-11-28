type NetworkSample = {
  url: string;
  method: "GET";
  status: 200;
  body: string;
  headers: Record<string, string>;
};

function sampleResponse(url: string, body: string, contentType: string, headers: Record<string, string> = {}): NetworkSample {
  return { url, method: "GET", status: 200, body, headers: { "content-type": contentType, ...headers } };
}

function sampleJSON(url: string, value: unknown, headers?: Record<string, string>): NetworkSample {
  return sampleResponse(url, JSON.stringify(value), "application/json", headers);
}

// These responses are synthetic and use the exact URLs of the default examples.
// The browser sandbox does not fetch from these providers.
export function sampleNetworkResponses(now: number): NetworkSample[] {
  const hour = 3_600_000;
  const day = 24 * hour;
  const start = Math.floor(now / hour) * hour;
  const today = new Date(now).toISOString().slice(0, 10);
  const tomorrow = new Date(now + day).toISOString().slice(0, 10);
  const airDate = new Date(now + 2 * day).toISOString().slice(0, 19).replace("T", " ");
  const weather = {
    properties: {
      meta: {
        updated_at: new Date(start).toISOString(),
        units: { air_temperature: "celsius", relative_humidity: "%", wind_speed: "m/s" },
      },
      timeseries: Array.from({ length: 24 }, (_, index) => ({
        time: new Date(start + index * hour).toISOString(),
        data: {
          instant: { details: { air_temperature: 21 + index / 4, relative_humidity: 62, wind_speed: 2 } },
          next_1_hours: { summary: { symbol_code: "partlycloudy_day" } },
        },
      })),
    },
  };

  return [
    sampleJSON("https://api.github.com/repos/everettjf/scriptwidget", {
      full_name: "everettjf/scriptwidget", private: false, stargazers_count: 1280, forks_count: 96, open_issues_count: 18,
    }, { "cache-control": "public, max-age=3600" }),
    sampleJSON("https://api.example.com/data", { value: 42 }),
    sampleJSON("https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=37.33&lon=-122.01", weather, {
      expires: new Date(now + hour).toUTCString(),
      "last-modified": new Date(start).toUTCString(),
    }),
    sampleJSON(
      "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=37.7749&longitude=-122.4194&current=pm2_5,pm10,us_aqi&timezone=auto",
      { current: { pm2_5: 9.5, pm10: 16.1, us_aqi: 42 } },
    ),
    sampleJSON(
      "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd&include_24hr_change=true",
      { bitcoin: { usd: 64000, usd_24h_change: 2.75 } },
    ),
    sampleJSON("https://open.er-api.com/v6/latest/USD", {
      result: "success", base_code: "USD", rates: { USD: 1, CNY: 7.21, EUR: 0.92, JPY: 151.16 },
    }),
    sampleJSON("https://zenquotes.io/api/today", [{ q: "Small steps make room for big ideas.", a: "ScriptWidget sample" }]),
    sampleJSON("https://www.episodate.com/api/show-details?q=the-lord-of-the-rings", {
      tvShow: { name: "The Rings of Power", countdown: { season: 2, episode: 5, air_date: airDate } },
    }),
    sampleJSON("https://www.episodate.com/api/show-details?q=house-of-the-dragon", {
      tvShow: { name: "House of the Dragon", countdown: null },
    }),
    sampleResponse(
      "https://stooq.com/q/l/?s=aapl.us&i=d",
      "Symbol,Date,Open,High,Low,Close,Volume\nAAPL.US,2026-01-02,185.40,189.00,184.75,188.36,40000000\n",
      "text/csv",
    ),
    sampleJSON("https://api.sunrise-sunset.org/json?lat=37.7749&lng=-122.4194&formatted=0", {
      status: "OK", results: { sunrise: `${today}T14:30:00+00:00`, sunset: `${tomorrow}T01:40:00+00:00` },
    }),
    sampleJSON(
      "https://api.open-meteo.com/v1/forecast?latitude=39.9042&longitude=116.4074&current=temperature_2m,wind_speed_10m,weather_code&timezone=auto",
      { current: { temperature_2m: 23, wind_speed_10m: 12, weather_code: 2 } },
    ),
    sampleJSON(
      "https://api.open-meteo.com/v1/forecast?latitude=39.9042&longitude=116.4074&current=temperature_2m,apparent_temperature,weather_code&timezone=auto",
      { current: { temperature_2m: 23, apparent_temperature: 21, weather_code: 2 } },
    ),
  ];
}
