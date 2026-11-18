var repositoryStats = (() => {
  const key = "github.stats.v1",
    hour = 3600000,
    day = 24 * hour;
  const defaults = { repository: "everettjf/ScriptWidget", accent: "blue" };
  const closed = (value, keys) =>
    value &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    Object.keys(value).sort().join(",") === keys.split(",").sort().join(",");
  const count = (value) => Number.isSafeInteger(value) && value >= 0 && value <= 1000000000;
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
  function validate(value) {
    if (
      !closed(value, "repository,accent") ||
      !validRepository(value.repository) ||
      !["blue", "green", "rose"].includes(value.accent)
    )
      throw new Error("Choose a public owner/repository and an accent in Records & Configuration.");
    return value;
  }
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
  const validDate = (value) =>
    typeof value === "string" &&
    value.length <= 128 &&
    /^[A-Za-z]{3}, \d{2} [A-Za-z]{3} \d{4} \d{2}:\d{2}:\d{2} GMT$/.test(value) &&
    Number.isFinite(Date.parse(value));
  const validValues = (value) =>
    closed(value, "stars,forks,issues") &&
    count(value.stars) &&
    count(value.forks) &&
    count(value.issues);
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
      for (const point of history) {
        if (
          daily.length &&
          Math.floor(daily[daily.length - 1].time / day) === Math.floor(point.time / day)
        )
          daily[daily.length - 1] = point;
        else daily.push(point);
      }
      const merged = { ...candidate, history: candidate.values === null ? [] : daily.slice(-14) };
      const next = [merged, ...entries.filter((entry) => entry.repository !== packet.repository)]
        .sort((a, b) => b.checkedAt - a.checkedAt)
        .slice(0, 4);
      if ($storage.compareAndSetString(key, raw, JSON.stringify({ version: 1, entries: next })))
        return true;
    }
    return false;
  }
  function nextRequest(headers, now) {
    const expiry = Date.parse(headers.expires || ""),
      maxAge = /(?:^|,)\s*max-age=(\d+)/i.exec(headers["cache-control"] || "");
    const until = maxAge ? now + Number(maxAge[1]) * 1000 : expiry;
    return Math.round(
      Math.max(now + hour, Number.isFinite(until) && until <= now + 7 * day ? until : now + hour),
    );
  }
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
  async function load(config, now, projection) {
    validate(config);
    const repository = config.repository.toLowerCase();
    let packet = packets($storage.getString(key), now).find(
        (entry) => entry.repository === repository,
      ),
      saved = true,
      fromCache = !!packet;
    if (!projection && (!packet || now >= packet.nextRequestAt)) {
      const previous = packet;
      const headers = {
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "ScriptWidget/1.3 (https://github.com/everettjf/scriptwidget)",
      };
      if (packet?.lastModified) headers["If-Modified-Since"] = packet.lastModified;
      let responseHeaders = {},
        reason = "offline",
        missing = false;
      try {
        const response = await $http.getResponse(
          `https://api.github.com/repos/${repository.split("/").map(encodeURIComponent).join("/")}`,
          { headers },
        );
        if (!response || !Number.isInteger(response.status)) throw new Error("Invalid response");
        responseHeaders = response.headers || {};
        if (response.status === 304 && packet?.values) {
          packet = {
            ...packet,
            checkedAt: now,
            observedAt: now,
            nextRequestAt: nextRequest(responseHeaders, now),
            reason: "",
          };
        } else if (response.status === 200) {
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
    const message =
      packet?.reason === "rate"
        ? "GitHub rate limit"
        : packet?.reason === "missing"
          ? "Repository unavailable"
          : packet?.reason === "invalid"
            ? "Invalid service response"
            : "Refresh unavailable";
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
    const minutes = Math.max(0, Math.floor((now - packet.observedAt) / 60000)),
      age =
        minutes < 1
          ? "Checked just now"
          : minutes < 60
            ? `Checked ${minutes}m ago`
            : minutes < 1440
              ? `Checked ${Math.floor(minutes / 60)}h ago`
              : `Checked ${Math.floor(minutes / 1440)}d ago`;
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
