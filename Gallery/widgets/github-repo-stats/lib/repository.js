// Loads the public counts of one GitHub repository and keeps a copy in $storage, so the
// widget still has numbers when it is offline or when GitHub limits requests.
// main.jsx imports this file ("lib/repository.js") and uses `repositoryStats`.
var repositoryStats = (() => {
  // The storage key of the saved copy, and two time spans in milliseconds.
  const key = "github.stats.v1",
    hour = 3600000,
    day = 24 * hour;
  const defaults = { repository: "everettjf/scriptwidget", accent: "blue" };
  // True when `value` is a plain object with exactly the keys listed in `keys` ("a,b,c").
  const closed = (value, keys) =>
    value &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    Object.keys(value).sort().join(",") === keys.split(",").sort().join(",");
  // A whole number from 0 to one billion.
  const count = (value) => Number.isSafeInteger(value) && value >= 0 && value <= 1000000000;
  // True for "owner/name" written the way GitHub allows.
  function validRepository(value) {
    if (typeof value !== "string" || value.length > 140) return false;
    const parts = value.split("/");
    return (
      parts.length === 2 &&
      /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/.test(parts[0]) &&
      /^[A-Za-z0-9_.-]{1,100}$/.test(parts[1]) &&
      ![".", ".."].includes(parts[1])
    );
  }
  // Check the settings { repository, accent }, or throw a message the app can show.
  function validate(value) {
    if (
      !closed(value, "repository,accent") ||
      !validRepository(value.repository) ||
      !["blue", "green", "rose"].includes(value.accent)
    )
      throw new Error("Choose a public owner/repository and an accent in Records & Configuration.");
    return value;
  }
  // Work out the settings: the defaults, then the configuration saved by Records &
  // Configuration (`raw`), then the widget parameter. The parameter is owner/name, or JSON
  // such as {"repository":"owner/name","accent":"green"}.
  function options(raw, parameter) {
    let result = { ...defaults };
    if (raw !== null && raw !== undefined && raw !== "") {
      if (typeof raw !== "string" || raw.length > 4096)
        throw new Error("Invalid repository configuration.");
      const saved = JSON.parse(raw);
      if (
        !closed(saved, "version,kind,values") ||
        saved.version !== 1 ||
        saved.kind !== "repoStats"
      )
        throw new Error("Invalid repository configuration.");
      result = { ...validate(saved.values) };
    }
    if (parameter) {
      if (typeof parameter !== "string" || parameter.length > 4096)
        throw new Error("Invalid repository parameter.");
      if (parameter.trim().startsWith("{")) {
        const override = JSON.parse(parameter);
        if (
          !override ||
          typeof override !== "object" ||
          Array.isArray(override) ||
          Object.keys(override).some((key) => !Object.hasOwn(defaults, key))
        )
          throw new Error("Unknown repository setting.");
        result = { ...result, ...override };
      } else result.repository = parameter.trim();
    }
    return validate(result);
  }
  // An HTTP date such as "Sun, 08 Mar 2026 12:00:00 GMT", as in the Last-Modified header.
  const validDate = (value) =>
    typeof value === "string" &&
    value.length <= 128 &&
    /^[A-Za-z]{3}, \d{2} [A-Za-z]{3} \d{4} \d{2}:\d{2}:\d{2} GMT$/.test(value) &&
    Number.isFinite(Date.parse(value));
  // The three counts and nothing else.
  const validValues = (value) =>
    closed(value, "stars,forks,issues") &&
    count(value.stars) &&
    count(value.forks) &&
    count(value.issues);
  // Read the saved copy: up to 4 repositories, each with its counts, when it was checked
  // (`checkedAt`), when to ask again (`nextRequestAt`) and up to 14 daily star counts.
  // Times are milliseconds since 1970. Anything unexpected gives an empty list, so a
  // damaged copy is simply loaded again.
  function packets(raw, now) {
    try {
      if (typeof raw !== "string" || raw.length > 32768) return [];
      const data = JSON.parse(raw);
      if (
        !closed(data, "version,entries") ||
        data.version !== 1 ||
        !Array.isArray(data.entries) ||
        data.entries.length > 4
      )
        return [];
      const seen = new Set();
      for (const entry of data.entries) {
        if (
          !closed(
            entry,
            "repository,checkedAt,nextRequestAt,observedAt,lastModified,reason,values,history",
          ) ||
          !validRepository(entry.repository) ||
          entry.repository !== entry.repository.toLowerCase() ||
          seen.has(entry.repository) ||
          !Number.isSafeInteger(entry.checkedAt) ||
          entry.checkedAt < 0 ||
          entry.checkedAt > now + 60000 ||
          !Number.isSafeInteger(entry.nextRequestAt) ||
          entry.nextRequestAt < entry.checkedAt ||
          entry.nextRequestAt > entry.checkedAt + 7 * day ||
          !Number.isSafeInteger(entry.observedAt) ||
          entry.observedAt < 0 ||
          entry.observedAt > entry.checkedAt ||
          !["", "offline", "rate", "missing", "invalid"].includes(entry.reason) ||
          (entry.lastModified !== "" && !validDate(entry.lastModified)) ||
          (entry.values !== null && !validValues(entry.values)) ||
          (entry.values === null ? entry.observedAt !== 0 : entry.observedAt === 0) ||
          !Array.isArray(entry.history) ||
          entry.history.length > 14 ||
          entry.history.some(
            (point, index) =>
              !closed(point, "time,stars") ||
              !count(point.stars) ||
              !Number.isSafeInteger(point.time) ||
              point.time < 0 ||
              point.time > entry.observedAt ||
              (index > 0 &&
                Math.floor(point.time / day) <= Math.floor(entry.history[index - 1].time / day)),
          ) ||
          (entry.values === null && entry.history.length > 0)
        )
          return [];
        seen.add(entry.repository);
      }
      return data.entries;
    } catch {
      return [];
    }
  }
  // Save one repository's entry next to the others. compareAndSetString writes only if the
  // stored text is still `raw`; if something else saved in between, read again and retry.
  function publish(packet, now) {
    for (let attempt = 0; attempt < 4; attempt++) {
      const raw = $storage.getString(key),
        entries = packets(raw, now),
        previous = entries.find((entry) => entry.repository === packet.repository);
      if (previous && previous.checkedAt > packet.checkedAt) return true;
      // Keep newer successful data if an older failed request completes at the same timestamp.
      const candidate =
        previous?.values && previous.observedAt > packet.observedAt && packet.reason !== "missing"
          ? {
              ...packet,
              values: previous.values,
              observedAt: previous.observedAt,
              lastModified: previous.lastModified,
              history: previous.history,
              nextRequestAt: Math.max(packet.nextRequestAt, previous.nextRequestAt),
            }
          : packet;
      const history = [...(previous?.history || []), ...candidate.history].sort(
          (a, b) => a.time - b.time,
        ),
        daily = [];
      // Keep one history point per day (UTC); a later point replaces an earlier one of that day.
      for (const point of history) {
        if (
          daily.length &&
          Math.floor(daily[daily.length - 1].time / day) === Math.floor(point.time / day)
        )
          daily[daily.length - 1] = point;
        else daily.push(point);
      }
      const merged = { ...candidate, history: candidate.values === null ? [] : daily.slice(-14) };
      // Newest first, and never more than 4 repositories.
      const next = [merged, ...entries.filter((entry) => entry.repository !== packet.repository)]
        .sort((a, b) => b.checkedAt - a.checkedAt)
        .slice(0, 4);
      if ($storage.compareAndSetString(key, raw, JSON.stringify({ version: 1, entries: next })))
        return true;
    }
    return false;
  }
  // When to ask GitHub again after an answer: when the response says it expires
  // (Cache-Control max-age, else Expires), but not sooner than one hour. A missing time,
  // or one more than 7 days away, also gives one hour.
  function nextRequest(headers, now) {
    const expiry = Date.parse(headers.expires || ""),
      maxAge = /(?:^|,)\s*max-age=(\d+)/i.exec(headers["cache-control"] || "");
    const until = maxAge ? now + Number(maxAge[1]) * 1000 : expiry;
    return Math.round(
      Math.max(now + hour, Number.isFinite(until) && until <= now + 7 * day ? until : now + hour),
    );
  }
  // When to ask again after a failure: at the Retry-After time (seconds or a date) if it
  // is within 7 days, but not sooner than one hour; otherwise in one hour.
  function retry(headers, now) {
    const raw = headers["retry-after"] || "",
      seconds = /^\d+$/.test(raw) ? Number(raw) : NaN;
    const until = Number.isFinite(seconds) ? now + seconds * 1000 : Date.parse(raw);
    return Math.round(
      Number.isFinite(until) && until > now && until <= now + 7 * day
        ? Math.max(now + hour, until)
        : now + hour,
    );
  }
  // Take the three counts out of GitHub's answer, after checking that it describes the
  // public repository that was asked for.
  function values(body, repository) {
    if (typeof body !== "string" || body.length > 2097152)
      throw new Error("Invalid repository response");
    const data = JSON.parse(body);
    if (
      !data ||
      typeof data.full_name !== "string" ||
      data.full_name.toLowerCase() !== repository ||
      data.private !== false ||
      !count(data.stargazers_count) ||
      !count(data.forks_count) ||
      !count(data.open_issues_count)
    )
      throw new Error("Invalid public repository response");
    return {
      stars: data.stargazers_count,
      forks: data.forks_count,
      issues: data.open_issues_count,
    };
  }
  // load(config, now, projection) returns what the widget shows. `now` is in milliseconds.
  // `projection` is true for a future timeline entry, which must not use the network.
  async function load(config, now, projection) {
    validate(config);
    const repository = config.repository.toLowerCase();
    let packet = packets($storage.getString(key), now).find(
        (entry) => entry.repository === repository,
      ),
      saved = true,
      fromCache = !!packet;
    // Ask GitHub only when there is no saved copy or it is due for a refresh.
    if (!projection && (!packet || now >= packet.nextRequestAt)) {
      const previous = packet;
      const headers = {
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "ScriptWidget/1.3 (https://github.com/everettjf/scriptwidget)",
      };
      // With If-Modified-Since, GitHub can answer 304 "not changed" instead of the counts.
      if (packet?.lastModified) headers["If-Modified-Since"] = packet.lastModified;
      let responseHeaders = {},
        reason = "offline",
        missing = false;
      try {
        // $http.getResponse resolves to { status, body, headers }, also for statuses such as
        // 404; it throws only when the request itself fails.
        const response = await $http.getResponse(
          `https://api.github.com/repos/${repository.split("/").map(encodeURIComponent).join("/")}`,
          { headers },
        );
        if (!response || !Number.isInteger(response.status)) throw new Error("Invalid response");
        responseHeaders = response.headers || {};
        // 304: nothing changed, the saved counts are still right.
        if (response.status === 304 && packet?.values) {
          packet = {
            ...packet,
            checkedAt: now,
            observedAt: now,
            nextRequestAt: nextRequest(responseHeaders, now),
            reason: "",
          };
        } else if (response.status === 200) {
          // 200: new counts. Add today's stars to the history, one point per day.
          reason = "invalid";
          const result = values(response.body, repository),
            history = [...(packet?.history || [])].filter(
              (point) => Math.floor(point.time / day) !== Math.floor(now / day),
            );
          history.push({ time: now, stars: result.stars });
          packet = {
            repository,
            checkedAt: now,
            observedAt: now,
            nextRequestAt: nextRequest(responseHeaders, now),
            lastModified:
              validDate(responseHeaders["last-modified"]) &&
              Date.parse(responseHeaders["last-modified"]) <= now + 60000
                ? responseHeaders["last-modified"]
                : "",
            reason: "",
            values: result,
            history: history.slice(-14),
          };
        } else {
          // 403 and 429 mean a rate limit, 404 an unknown or private repository.
          reason =
            response.status === 403 || response.status === 429
              ? "rate"
              : response.status === 404
                ? "missing"
                : "offline";
          missing = response.status === 404;
          throw new Error("Service unavailable");
        }
        fromCache = response.status === 304;
      } catch {
        // No usable answer: keep the earlier counts (unless the repository is gone) and note why.
        packet = {
          repository,
          checkedAt: now,
          nextRequestAt: retry(responseHeaders, now),
          observedAt: missing ? 0 : previous?.observedAt || 0,
          lastModified: missing ? "" : previous?.lastModified || "",
          reason,
          values: missing ? null : previous?.values || null,
          history: missing ? [] : previous?.history || [],
        };
      }
      saved = publish(packet, now);
    }
    // A short text for the reason of the last failure.
    const message =
      packet?.reason === "rate"
        ? "GitHub rate limit"
        : packet?.reason === "missing"
          ? "Repository unavailable"
          : packet?.reason === "invalid"
            ? "Invalid service response"
            : "Refresh unavailable";
    // No counts, or counts older than 7 days: return a message to show instead.
    if (!packet?.values || now - packet.observedAt > 7 * day)
      return {
        available: false,
        repository: config.repository,
        heading: projection ? "Refresh in current entry" : message,
        detail:
          packet?.reason === "missing"
            ? "Check the public owner/repository. Private or deleted repositories cannot be read."
            : "Check your connection and try again later.",
        saved,
      };
    // How long ago the counts were read, as text.
    const minutes = Math.max(0, Math.floor((now - packet.observedAt) / 60000)),
      age =
        minutes < 1
          ? "Checked just now"
          : minutes < 60
            ? `Checked ${minutes}m ago`
            : minutes < 1440
              ? `Checked ${Math.floor(minutes / 60)}h ago`
              : `Checked ${Math.floor(minutes / 1440)}d ago`;
    // The counts, plus the texts for the last two lines of the widget.
    return {
      available: true,
      repository: config.repository,
      ...packet.values,
      history: packet.history,
      age,
      saved,
      status: !saved
        ? "Cache unavailable"
        : packet.reason
          ? `Saved counts · ${message.toLowerCase()}`
          : projection || fromCache
            ? "Saved counts"
            : "GitHub · Public repository",
    };
  }
  return { options, load };
})();
