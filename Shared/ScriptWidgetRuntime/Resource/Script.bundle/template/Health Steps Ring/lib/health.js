// Query only the selected metric. Never persist HealthKit readings or authorization.
// main.jsx imports this file ("lib/health.js") and then uses `healthCard`.
var healthCard = (() => {
  // metric is "steps", "energy" or "heart". The goals are steps and kcal per day.
  const defaults = { metric: "steps", stepsGoal: 8000, energyGoal: 500 };
  // Check the settings, or throw a message the app can show.
  function validate(value) {
    if (
      !value ||
      typeof value !== "object" ||
      Array.isArray(value) ||
      Object.keys(value).sort().join(",") !== "energyGoal,metric,stepsGoal" ||
      !["steps", "energy", "heart"].includes(value.metric) ||
      !Number.isInteger(value.stepsGoal) ||
      value.stepsGoal < 1 ||
      value.stepsGoal > 100000 ||
      !Number.isInteger(value.energyGoal) ||
      value.energyGoal < 1 ||
      value.energyGoal > 10000
    )
      throw new Error("Choose a metric and valid goals in Records & Configuration.");
    return value;
  }
  // Work out the settings: the defaults, then the configuration saved by Records &
  // Configuration (`raw`), then the widget parameter, which is JSON such as
  // {"metric":"heart"}.
  function options(raw, parameter) {
    let result = { ...defaults };
    if (raw !== null && raw !== undefined && raw !== "") {
      if (typeof raw !== "string" || raw.length > 4096)
        throw new Error("Invalid saved health configuration.");
      const saved = JSON.parse(raw);
      if (
        !saved ||
        Object.keys(saved).sort().join(",") !== "kind,values,version" ||
        saved.kind !== "healthCard" ||
        saved.version !== 1
      )
        throw new Error("Invalid saved health configuration.");
      result = { ...validate(saved.values) };
    }
    if (parameter) {
      if (typeof parameter !== "string" || parameter.length > 4096)
        throw new Error("Invalid health parameter.");
      const overrides = JSON.parse(parameter);
      if (
        !overrides ||
        typeof overrides !== "object" ||
        Array.isArray(overrides) ||
        Object.keys(overrides).some((key) => !Object.hasOwn(defaults, key))
      )
        throw new Error("Unknown health setting.");
      result = { ...result, ...overrides };
    }
    return validate(result);
  }
  // load(config, now, projection) returns what the widget shows. `now` is in milliseconds.
  // `projection` is true for a future timeline entry, which gets no reading.
  async function load(config, now, projection) {
    validate(config);
    const metric = config.metric;
    // Title, icon and color of the chosen metric.
    const title =
      metric === "steps"
        ? "Steps today"
        : metric === "energy"
          ? "Active energy"
          : "Latest heart rate";
    const icon =
      metric === "steps" ? "figure.walk" : metric === "energy" ? "flame.fill" : "heart.fill";
    const color = metric === "steps" ? "#2563eb" : metric === "energy" ? "#c2410c" : "#be185d";
    // The result when there is no number: a heading and one line of explanation.
    const empty = (heading, detail) => ({ available: false, title, icon, color, heading, detail });
    if (projection)
      return empty(
        "Refresh in current entry",
        "Health readings are queried only for the current entry.",
      );
    // isAvailable() is false on a system without Health data.
    if (!$health.isAvailable())
      return empty(
        "Health on iPhone",
        "Install on iPhone and enable Health in ScriptWidget Settings.",
      );
    // Health does not tell an app whether reading was allowed, so this only stops when
    // Health is not available or not set up.
    const authorization = $health.authorizationStatus();
    if (["unavailable", "undeclared", "denied", "notDetermined"].includes(authorization))
      return empty("Connect Health", "Enable Health in ScriptWidget Settings on iPhone.");
    let reading;
    // Ask Health for the chosen metric only. `await` waits for the answer.
    try {
      reading = await (metric === "steps"
        ? $health.stepCountToday()
        : metric === "energy"
          ? $health.activeEnergyToday()
          : $health.heartRateLatest());
    } catch {
      return empty(
        "Health unavailable",
        "Open ScriptWidget to check access; locked devices may delay readings.",
      );
    }
    // No samples. A value of 0 without the hasSamples flag is treated the same way.
    if (
      !reading ||
      typeof reading !== "object" ||
      reading.hasSamples === false ||
      (reading.hasSamples !== true && reading.value === 0)
    )
      return empty(
        "No readable data",
        "Check Health access and recorded samples. Read permission is not disclosed.",
      );
    if (reading.hasSamples !== undefined && typeof reading.hasSamples !== "boolean")
      return empty("Reading unavailable", "Invalid sample metadata. Refresh later.");
    // Accept the reading only with the expected unit, a believable value and a recent end:
    // within 15 minutes for today's totals, 24 hours for the heart rate.
    const unit = metric === "steps" ? "count" : metric === "energy" ? "kcal" : "bpm";
    const start = Date.parse(reading.start),
      end = Date.parse(reading.end),
      limit = metric === "heart" ? 24 * 3600000 : 15 * 60000;
    if (
      reading.unit !== unit ||
      typeof reading.value !== "number" ||
      !Number.isFinite(reading.value) ||
      reading.value < (metric === "heart" ? 1 : 0) ||
      reading.value > (metric === "steps" ? 1000000 : metric === "energy" ? 100000 : 300) ||
      !Number.isFinite(start) ||
      !Number.isFinite(end) ||
      start > end ||
      end > now + 60000 ||
      now - end > limit
    )
      return empty("Reading unavailable", "No recent valid sample. Open Health and refresh later.");
    // A total that began on another day is not today's total.
    if (metric !== "heart") {
      const today = new Date(now),
        begin = new Date(start);
      today.setHours(0, 0, 0, 0);
      begin.setHours(0, 0, 0, 0);
      if (today.getTime() !== begin.getTime())
        return empty("Refresh for today", "Yesterday’s total is not shown as today’s activity.");
    }
    // Heart rate has no goal.
    const goal =
      metric === "steps" ? config.stepsGoal : metric === "energy" ? config.energyGoal : null;
    // Whole minutes since the end of the reading.
    const minutes = Math.max(0, Math.floor((now - end) / 60000));
    // The result for main.jsx. `progress` is value / goal, at most 1.
    return {
      available: true,
      title,
      icon,
      color,
      value: Math.round(reading.value),
      unit: metric === "steps" ? "steps" : unit,
      goal,
      progress: goal === null ? null : Math.min(1, reading.value / goal),
      age:
        minutes < 1
          ? "Updated just now"
          : minutes < 60
            ? `Updated ${minutes}m ago`
            : `Sample ${Math.floor(minutes / 60)}h ago`,
      detail:
        metric === "heart"
          ? "Latest sample · not live"
          : `Goal ${goal} ${metric === "steps" ? "steps" : "kcal"}`,
    };
  }
  return { options, load };
})();
