// MET Norway Locationforecast 2.0. Forecasts are model data, not observations.
// https://api.met.no/doc/TermsOfService · https://api.met.no/doc/License
// main.jsx imports this file ("lib/weather.js") and then uses `localWeather`.
// It chooses the place, asks MET Norway for its forecast and keeps a copy in $storage.
var localWeather = (() => {
  // The storage key of the saved forecasts, and one hour in milliseconds.
  const cacheKey = "weather.met.v1",
    hour = 3600000;
  // The settings. `unit` is "c" or "f"; `city` with its coordinates is the saved city.
  const defaults = { city: "", latitude: 0, longitude: 0, useLocation: true, unit: "c" };
  // True for a real number between min and max.
  const numeric = (value, min, max) =>
    typeof value === "number" && Number.isFinite(value) && value >= min && value <= max;
  // The keys of a plain object, sorted and joined ("a,b,c"); "" for anything else.
  const keys = (object) =>
    object && typeof object === "object" && !Array.isArray(object)
      ? Object.keys(object).sort().join(",")
      : "";
  function validOptions(value) {
    return (
      keys(value) === "city,latitude,longitude,unit,useLocation" &&
      typeof value.city === "string" &&
      value.city.length <= 60 &&
      numeric(value.latitude, -90, 90) &&
      numeric(value.longitude, -180, 180) &&
      typeof value.useLocation === "boolean" &&
      ["c", "f"].includes(value.unit)
    );
  }
  // Work out the settings: the defaults, then the configuration saved by Records &
  // Configuration (`raw`), then the widget parameter: JSON, or latitude,longitude,City.
  function options(raw, parameter) {
    let value = { ...defaults };
    if (raw !== "") {
      let state;
      try {
        state = JSON.parse(raw);
      } catch (_) {
        throw new Error(
          "Saved weather settings are invalid. Open Records & Configuration to repair them.",
        );
      }
      if (
        typeof raw !== "string" ||
        // unescape(encodeURIComponent(text)).length is the size of the text in UTF-8 bytes.
        unescape(encodeURIComponent(raw)).length > 4096 ||
        keys(state) !== "kind,values,version" ||
        state.version !== 1 ||
        state.kind !== "weather" ||
        !validOptions(state.values)
      )
        throw new Error(
          "Saved weather settings are invalid. Open Records & Configuration to repair them.",
        );
      value = state.values;
    }
    parameter = (parameter || "").trim();
    if (parameter) {
      if (parameter[0] === "{") {
        let custom;
        try {
          custom = JSON.parse(parameter);
        } catch (_) {
          throw new Error("Weather parameters must be valid JSON.");
        }
        if (
          !custom ||
          Array.isArray(custom) ||
          Object.keys(custom).some((key) => !Object.prototype.hasOwnProperty.call(defaults, key))
        )
          throw new Error(
            "Weather settings accept city, latitude, longitude, useLocation and unit only.",
          );
        value = { ...value, ...custom };
      } else {
        // latitude,longitude with an optional city name. A fixed place turns location off.
        const parts = parameter.split(",").map((value) => value.trim());
        if (
          parts.length < 2 ||
          parts.length > 3 ||
          parts.slice(0, 2).some((value) => !/^[+-]?(?:\d+(?:\.\d+)?|\.\d+)$/.test(value))
        )
          throw new Error("Use latitude,longitude or JSON weather settings.");
        value = {
          ...value,
          city: parts[2] || "Selected city",
          latitude: Number(parts[0]),
          longitude: Number(parts[1]),
          useLocation: false,
        };
      }
    }
    if (!validOptions(value))
      throw new Error(
        "Choose valid coordinates, a city label up to 60 characters and Celsius or Fahrenheit.",
      );
    return value;
  }
  // Coordinates are rounded to 2 decimals, roughly a kilometre, before use.
  const rounded = (value) => Number(value.toFixed(2));
  // The name of a place in the saved copy, such as "manual:59.91,10.75".
  const placeKey = (source, latitude, longitude) =>
    `${source}:${rounded(latitude).toFixed(2)},${rounded(longitude).toFixed(2)}`;
  const validHTTPDate = (value) =>
    typeof value === "string" &&
    /^[A-Za-z0-9,: -]{1,128}$/.test(value) &&
    Number.isFinite(Date.parse(value));
  // One forecast point: time (ms), temperature (°C), humidity (%), wind (m/s), symbol code.
  function validPoint(point) {
    return (
      keys(point) === "humidity,symbol,temperature,time,wind" &&
      Number.isSafeInteger(point.time) &&
      point.time > 0 &&
      numeric(point.temperature, -100, 70) &&
      (point.humidity === null || numeric(point.humidity, 0, 100)) &&
      (point.wind === null || numeric(point.wind, 0, 160)) &&
      typeof point.symbol === "string" &&
      /^[a-z_]{1,64}$/.test(point.symbol)
    );
  }
  function validPlaceKey(key, source) {
    if (typeof key !== "string") return false;
    const match = /^(manual|location):(-?\d{1,3}\.\d{2}),(-?\d{1,3}\.\d{2})$/.exec(key);
    return (
      !!match &&
      match[1] === source &&
      numeric(Number(match[2]), -90, 90) &&
      numeric(Number(match[3]), -180, 180)
    );
  }
  // Read the saved copy: up to 4 places with up to 24 forecast points each.
  // Anything unexpected gives an empty list, so a damaged copy is simply loaded again.
  function packets(raw, now) {
    try {
      if (typeof raw !== "string" || unescape(encodeURIComponent(raw)).length > 64000) return [];
      const state = JSON.parse(raw);
      if (
        keys(state) !== "entries,version" ||
        state.version !== 1 ||
        !Array.isArray(state.entries) ||
        state.entries.length > 4
      )
        return [];
      const names = new Set();
      for (const entry of state.entries) {
        if (
          keys(entry) !==
            "checkedAt,deprecated,failed,key,lastModified,nextRequestAt,points,source,updatedAt" ||
          !["manual", "location"].includes(entry.source) ||
          !validPlaceKey(entry.key, entry.source) ||
          names.has(entry.key) ||
          !Number.isSafeInteger(entry.checkedAt) ||
          entry.checkedAt < 0 ||
          entry.checkedAt > now + 300000 ||
          !Number.isSafeInteger(entry.nextRequestAt) ||
          entry.nextRequestAt < entry.checkedAt ||
          entry.nextRequestAt > entry.checkedAt + 7 * 24 * hour ||
          !Number.isSafeInteger(entry.updatedAt) ||
          entry.updatedAt < 0 ||
          entry.updatedAt > now + 300000 ||
          typeof entry.failed !== "boolean" ||
          typeof entry.deprecated !== "boolean" ||
          (entry.lastModified !== "" && !validHTTPDate(entry.lastModified)) ||
          !Array.isArray(entry.points) ||
          entry.points.length > 24 ||
          !entry.points.every(validPoint) ||
          entry.points.some(
            (point, index) => index > 0 && point.time <= entry.points[index - 1].time,
          ) ||
          (entry.points.length === 0 ? entry.updatedAt !== 0 : entry.updatedAt === 0)
        )
          return [];
        names.add(entry.key);
      }
      return state.entries;
    } catch (_) {
      return [];
    }
  }
  // Save the forecast of one place next to the others; only one place found by location
  // is kept. compareAndSetString writes only if the stored text is still `raw`; if
  // something else saved in between, read again and retry.
  function publish(packet, now, projection) {
    if (projection) return false;
    for (let attempt = 0; attempt < 4; attempt++) {
      const raw = $storage.getString(cacheKey),
        entries = packets(raw, now);
      const previous = entries.find((entry) => entry.key === packet.key);
      if (
        previous &&
        (previous.updatedAt > packet.updatedAt || previous.checkedAt > packet.checkedAt)
      )
        return true;
      const next = [
        packet,
        ...entries.filter(
          (entry) =>
            entry.key !== packet.key &&
            (packet.source !== "location" || entry.source !== "location"),
        ),
      ]
        .sort((a, b) => b.checkedAt - a.checkedAt)
        .slice(0, 4);
      if (
        $storage.compareAndSetString(cacheKey, raw, JSON.stringify({ version: 1, entries: next }))
      )
        return true;
    }
    return false;
  }
  // When to ask again: when the response expires (Expires, else Cache-Control max-age),
  // or in one hour without a usable time. Never sooner than 15 minutes, plus up to 5
  // random minutes.
  function expires(headers, now) {
    let until = Date.parse(headers.expires || "");
    const maxAge = /(?:^|,)\s*max-age=(\d+)/i.exec(headers["cache-control"] || "");
    if (!Number.isFinite(until) && maxAge) until = now + Math.min(Number(maxAge[1]), 604800) * 1000;
    if (!Number.isFinite(until) || until > now + 7 * 24 * hour) until = now + hour;
    return Math.round(Math.max(now + 900000, until) + Math.random() * 300000);
  }
  // Check the answer of MET Norway and keep up to 24 points, starting 2 hours ago.
  function parseResponse(body, place, now, headers, status) {
    if (typeof body !== "string" || unescape(encodeURIComponent(body)).length > 2097152)
      throw new Error("Invalid forecast");
    const data = JSON.parse(body),
      meta = data?.properties?.meta,
      times = data?.properties?.timeseries;
    const updatedAt = Date.parse(meta?.updated_at || "");
    if (
      !Number.isFinite(updatedAt) ||
      updatedAt > now + 300000 ||
      now - updatedAt > 24 * hour ||
      meta?.units?.air_temperature !== "celsius" ||
      meta?.units?.wind_speed !== "m/s" ||
      !Array.isArray(times) ||
      times.length < 1 ||
      times.length > 250
    )
      throw new Error("Invalid forecast");
    const points = [];
    for (const item of times) {
      const time = Date.parse(item?.time || "");
      if (!Number.isFinite(time)) throw new Error("Invalid forecast time");
      if (time < now - 2 * hour || points.length >= 24) continue;
      const details = item?.data?.instant?.details,
        summary =
          item?.data?.next_1_hours?.summary ||
          item?.data?.next_6_hours?.summary ||
          item?.data?.next_12_hours?.summary;
      const point = {
        time,
        temperature: details?.air_temperature,
        humidity:
          meta.units.relative_humidity === "%" && numeric(details?.relative_humidity, 0, 100)
            ? details.relative_humidity
            : null,
        wind: numeric(details?.wind_speed, 0, 160) ? details.wind_speed : null,
        symbol: summary?.symbol_code || "unknown",
      };
      if (!validPoint(point) || (points.length && time <= points[points.length - 1].time))
        throw new Error("Invalid forecast point");
      points.push(point);
    }
    // One of the points must lie within 90 minutes of now.
    if (!points.some((point) => Math.abs(point.time - now) <= 90 * 60000))
      throw new Error("Forecast is unavailable");
    // Status 203 is how MET Norway announces that this version of the service will end.
    return {
      key: place.key,
      source: place.source,
      updatedAt,
      checkedAt: now,
      nextRequestAt: expires(headers, now),
      lastModified:
        validHTTPDate(headers["last-modified"]) &&
        Date.parse(headers["last-modified"]) <= now + 300000
          ? headers["last-modified"]
          : "",
      points,
      failed: false,
      deprecated: status === 203,
    };
  }
  // The forecast point for now: the latest one that is not in the future, provided it is
  // within 90 minutes of now and the forecast is less than a day old.
  function pointAt(packet, now) {
    if (
      !packet ||
      !packet.points.length ||
      now - packet.updatedAt > 24 * hour ||
      packet.updatedAt > now + 300000
    )
      return null;
    const earlier = packet.points.filter((point) => point.time <= now);
    const point = earlier[earlier.length - 1] || packet.points[0];
    return Math.abs(point.time - now) <= 90 * 60000 ? point : null;
  }
  // Turn a symbol code such as "partlycloudy_night" into a title and an SF Symbol name.
  function condition(symbol) {
    const night = symbol.endsWith("_night");
    if (symbol.includes("thunder")) return { title: "Thunderstorms", icon: "cloud.bolt.rain.fill" };
    if (symbol.includes("snow") || symbol.includes("sleet"))
      return { title: "Snow or sleet", icon: "cloud.snow.fill" };
    if (symbol.includes("rain")) return { title: "Rain", icon: "cloud.rain.fill" };
    if (symbol.includes("fog")) return { title: "Fog", icon: "cloud.fog.fill" };
    if (symbol.includes("partlycloudy") || symbol.startsWith("fair"))
      return { title: "Partly cloudy", icon: night ? "cloud.moon.fill" : "cloud.sun.fill" };
    if (symbol.startsWith("clearsky"))
      return { title: "Clear", icon: night ? "moon.stars.fill" : "sun.max.fill" };
    if (symbol.startsWith("cloudy")) return { title: "Cloudy", icon: "cloud.fill" };
    return { title: "Forecast", icon: "cloud.fill" };
  }
  // True when location exists here, the app may use it and widgets may use it too.
  const locationAllowed = () =>
    $location.isAvailable() &&
    ["authorizedWhenInUse", "authorizedAlways"].includes($location.authorizationStatus()) &&
    $location.isAuthorizedForWidgetUpdates();
  // Forget the forecast saved for a location once location is no longer allowed.
  function clearLocationCache(now, projection) {
    if (projection) return;
    for (let attempt = 0; attempt < 4; attempt++) {
      const raw = $storage.getString(cacheKey),
        filtered = packets(raw, now).filter((entry) => entry.source !== "location");
      if (
        $storage.compareAndSetString(
          cacheKey,
          raw,
          JSON.stringify({ version: 1, entries: filtered }),
        )
      )
        return;
    }
  }
  // Location was allowed and no longer is: use the saved city, if there is one.
  async function revoked(config, now, projection) {
    clearLocationCache(now, projection);
    return config.city.trim()
      ? await load({ ...config, useLocation: false }, now, projection)
      : {
          available: false,
          title: "Location access changed",
          hint: "Choose a saved city to continue.",
        };
  }
  // load(config, now, projection) returns what the widget shows. `now` is in milliseconds.
  // `projection` is true for a future timeline entry, which asks neither for the position
  // nor for a new forecast.
  async function load(config, now, projection) {
    let entries = packets($storage.getString(cacheKey), now);
    const authorized = locationAllowed();
    if (!authorized && entries.some((entry) => entry.source === "location")) {
      entries = entries.filter((entry) => entry.source !== "location");
      clearLocationCache(now, projection);
    }
    // Choose the place: the current position, else the last saved one, else the city.
    let place = null;
    if (config.useLocation && authorized) {
      if (!projection) {
        try {
          // maxAge: 3600 accepts a position up to one hour old; `age` is in seconds.
          const location = await $location.current({ maxAge: 3600 });
          const stale =
            location.isStale === true || (typeof location.age === "number" && location.age > 3600);
          if (
            !stale &&
            numeric(location.latitude, -90, 90) &&
            numeric(location.longitude, -180, 180)
          )
            place = {
              source: "location",
              name:
                location.accuracyAuthorization === "reduced" ? "Approximate area" : "Current area",
              latitude: rounded(location.latitude),
              longitude: rounded(location.longitude),
            };
        } catch (_) {}
      }
      if (!place && (!config.city.trim() || projection)) {
        const saved = entries.find((entry) => entry.source === "location" && pointAt(entry, now));
        if (saved)
          place = { source: "location", name: "Last location", key: saved.key, skipNetwork: true };
      }
    }
    if (!place && config.city.trim())
      place = {
        source: "manual",
        name: config.city,
        latitude: rounded(config.latitude),
        longitude: rounded(config.longitude),
      };
    if (!place)
      return {
        available: false,
        title: "Choose a saved city",
        hint: "Open Records & Configuration. Location is optional.",
      };
    place.key ??= placeKey(place.source, place.latitude, place.longitude);
    if (place.source === "location" && !locationAllowed()) {
      return await revoked(config, now, projection);
    }
    let packet = entries.find((entry) => entry.key === place.key),
      saved = true,
      fromCache = true;
    // Ask MET Norway only when there is no saved forecast for the place or it is due.
    if (!projection && !place.skipNetwork && (!packet || now >= packet.nextRequestAt)) {
      try {
        const headers = {
          "User-Agent": "ScriptWidget/1.3 (https://github.com/everettjf/scriptwidget)",
          Accept: "application/json",
        };
        if (packet?.lastModified) headers["If-Modified-Since"] = packet.lastModified;
        // The call resolves to { status, body, headers }, also for statuses such as 304.
        const response = await $http.getResponse(
          `https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=${place.latitude.toFixed(2)}&lon=${place.longitude.toFixed(2)}`,
          { headers, timeoutInterval: 4 },
        );
        if (place.source === "location" && !locationAllowed()) {
          return await revoked(config, now, projection);
        }
        const responseHeaders = response.headers || {};
        // 304: not changed since the last request, so the saved points stay.
        if (response.status === 304 && pointAt(packet, now))
          packet = {
            ...packet,
            checkedAt: now,
            nextRequestAt: expires(responseHeaders, now),
            failed: false,
          };
        else if (response.status === 200 || response.status === 203) {
          packet = parseResponse(response.body, place, now, responseHeaders, response.status);
          fromCache = false;
        } else {
          // Another status: retry at the Retry-After time, 15 minutes to 24 hours from now.
          const retry = responseHeaders["retry-after"] || "";
          let until = /^\d+$/.test(retry) ? now + Number(retry) * 1000 : Date.parse(retry);
          if (!Number.isFinite(until)) until = now + 900000;
          const error = new Error("Refresh unavailable");
          error.retryAt = Math.min(now + 24 * hour, Math.max(now + 900000, until));
          throw error;
        }
        saved = publish(packet, now, projection);
      } catch (error) {
        // No usable answer: keep the saved points and note the failure.
        if (place.source === "location" && !locationAllowed())
          return await revoked(config, now, projection);
        const retryAt = numeric(error?.retryAt, now, now + 24 * hour)
          ? error.retryAt
          : now + 900000;
        packet = packet || {
          key: place.key,
          source: place.source,
          updatedAt: 0,
          lastModified: "",
          points: [],
          deprecated: false,
        };
        packet = { ...packet, checkedAt: now, nextRequestAt: Math.round(retryAt), failed: true };
        saved = publish(packet, now, projection);
      }
    }
    if (place.source === "location" && !locationAllowed())
      return await revoked(config, now, projection);
    const point = pointAt(packet, now);
    if (!point)
      return {
        available: false,
        title: "Forecast unavailable",
        hint: "Check your connection or saved city, then refresh.",
      };
    // Temperatures are saved in °C and converted for display.
    const celsius = config.unit === "c",
      temperature = (value) =>
        Math.round(celsius ? value : (value * 9) / 5 + 32) + (celsius ? "°C" : "°F");
    // Minutes since MET Norway updated the forecast.
    const age = Math.max(0, Math.floor((now - packet.updatedAt) / 60000));
    const statusText = packet.deprecated
      ? "Service update needed"
      : !saved
        ? "Cache unavailable"
        : packet.failed
          ? "Saved forecast · refresh unavailable"
          : place.skipNetwork
            ? "Saved forecast · last location"
            : fromCache
              ? "Saved forecast"
              : "Forecast";
    const statusShort = packet.deprecated
      ? "Service update"
      : !saved
        ? "No cache"
        : packet.failed
          ? "Saved · refresh failed"
          : place.skipNetwork
            ? "Last location"
            : fromCache
              ? "Saved forecast"
              : "Forecast";
    // The result for main.jsx. Wind is converted from m/s to km/h (× 3.6).
    // `upcoming` holds the next 4 points, with labels such as "+3h".
    return {
      available: true,
      statusShort,
      name: place.name,
      source: place.source,
      condition: condition(point.symbol),
      temperature: temperature(point.temperature),
      humidity: point.humidity === null ? "—" : Math.round(point.humidity) + "%",
      wind: point.wind === null ? "—" : (point.wind * 3.6).toFixed(1) + " km/h",
      updated:
        age < 1
          ? "Updated just now"
          : age < 60
            ? `Updated ${age}m ago`
            : `Updated ${Math.floor(age / 60)}h ago`,
      status: statusText,
      upcoming: packet.points
        .filter((value) => value.time > point.time)
        .slice(0, 4)
        .map((value) => ({
          label: "+" + Math.max(1, Math.round((value.time - now) / hour)) + "h",
          temperature: temperature(value.temperature),
          condition: condition(value.symbol),
        })),
    };
  }
  return { options, load };
})();
