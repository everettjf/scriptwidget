// Calendar days use Gregorian ordinals, never elapsed 24-hour periods.
var CountdownCalendar = (() => {
  const defaults = {
    title: "Your next moment",
    targetDate: "",
    repeatYearly: false,
    accent: "blue",
  };
  function parts(text) {
    if (typeof text !== "string" || !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(text)) return null;
    const [year, month, day] = text.split("-").map(Number);
    if (year < 1970 || year > 9999) return null;
    const date = new Date(Date.UTC(year, month - 1, day));
    return date.getUTCFullYear() === year &&
      date.getUTCMonth() === month - 1 &&
      date.getUTCDate() === day
      ? [year, month, day]
      : null;
  }
  function validate(value) {
    return (
      value &&
      typeof value === "object" &&
      !Array.isArray(value) &&
      Object.keys(value).sort().join(",") === "accent,repeatYearly,targetDate,title" &&
      typeof value.title === "string" &&
      value.title.trim().length > 0 &&
      value.title.length <= 40 &&
      (value.targetDate === "" || !!parts(value.targetDate)) &&
      typeof value.repeatYearly === "boolean" &&
      ["blue", "rose", "green"].includes(value.accent)
    );
  }
  function configuration(raw, parameter) {
    let value = { ...defaults };
    if (raw !== "") {
      let state;
      try {
        state = JSON.parse(raw);
      } catch (_) {
        throw new Error(
          "Saved countdown configuration is invalid. Open Records & Configuration to repair it.",
        );
      }
      if (
        typeof raw !== "string" ||
        unescape(encodeURIComponent(raw)).length > 4096 ||
        !state ||
        Object.keys(state).sort().join(",") !== "kind,values,version" ||
        state.version !== 1 ||
        state.kind !== "countdown" ||
        !validate(state.values)
      ) {
        throw new Error(
          "Saved countdown configuration is invalid. Open Records & Configuration to repair it.",
        );
      }
      value = state.values;
    }
    parameter = (parameter || "").trim();
    if (!parameter) return { value, time: null };
    if (parameter[0] === "{") {
      let custom;
      try {
        custom = JSON.parse(parameter);
      } catch (_) {
        throw new Error("Use valid JSON for countdown settings.");
      }
      if (
        !custom ||
        Array.isArray(custom) ||
        Object.keys(custom).some((key) => !Object.prototype.hasOwnProperty.call(defaults, key))
      )
        throw new Error("Unknown countdown setting.");
      value = { ...value, ...custom };
      if (!validate(value))
        throw new Error("Use a valid event name, calendar date, repeat setting and accent.");
      return { value, time: null };
    }
    const match = /^(\d{4}-\d{2}-\d{2})(?:T(\d{2}):(\d{2}):(\d{2}))?(?:\s+(.+))?$/.exec(parameter);
    if (!match || !parts(match[1]))
      throw new Error("Use YYYY-MM-DD Event or YYYY-MM-DDTHH:mm:ss Event.");
    const time = match[2] === undefined ? null : match.slice(2, 5).map(Number);
    if (time && (time[0] > 23 || time[1] > 59 || time[2] > 59))
      throw new Error("Use a valid local time.");
    value = { ...value, title: match[5] || value.title, targetDate: match[1], repeatYearly: false };
    if (!validate(value)) throw new Error("Keep the event name to 40 characters.");
    return { value, time };
  }
  const ordinal = ([year, month, day]) => Date.UTC(year, month - 1, day) / 86400000;
  function describe(settings, now) {
    const value = settings.value;
    if (!Number.isFinite(now.getTime())) throw new Error("The preview date is invalid.");
    if (!value.targetDate)
      return {
        configured: false,
        title: value.title,
        number: "—",
        unit: "Choose a date",
        summary: "Set up your countdown",
        date: "Records & Configuration",
        accent: value.accent,
      };
    let target = parts(value.targetDate);
    const today = [now.getFullYear(), now.getMonth() + 1, now.getDate()];
    if (value.repeatYearly) {
      let next = null;
      for (let year = today[0]; year <= Math.min(9999, today[0] + 8); year++) {
        const text = `${year}-${String(target[1]).padStart(2, "0")}-${String(target[2]).padStart(2, "0")}`;
        const candidate = parts(text);
        if (candidate && ordinal(candidate) >= ordinal(today)) {
          next = candidate;
          break;
        }
      }
      if (!next) throw new Error("No upcoming occurrence in the supported date range.");
      target = next;
    }
    const days = ordinal(target) - ordinal(today);
    const dayWord = Math.abs(days) === 1 ? "day" : "days";
    let number = String(Math.abs(days)),
      unit = days === 0 ? "Today" : `${dayWord} ${days > 0 ? "to go" : "since"}`;
    let summary = days === 0 ? "Today" : `${Math.abs(days)} ${unit}`;
    if (settings.time) {
      const [hour, minute, second] = settings.time;
      const date = new Date(target[0], target[1] - 1, target[2], hour, minute, second);
      if (
        date.getFullYear() !== target[0] ||
        date.getMonth() !== target[1] - 1 ||
        date.getDate() !== target[2] ||
        date.getHours() !== hour ||
        date.getMinutes() !== minute ||
        date.getSeconds() !== second
      )
        throw new Error("That local time does not exist in this time zone.");
      const remaining = date.getTime() - now.getTime();
      const minutes = Math.ceil(Math.abs(remaining) / 60000);
      number =
        minutes >= 1440
          ? String(Math.floor(minutes / 1440))
          : minutes >= 60
            ? `${Math.floor(minutes / 60)}h ${minutes % 60}m`
            : `${minutes}m`;
      unit = remaining === 0 ? "Now" : remaining > 0 ? "until the moment" : "since the moment";
      summary = `${number} ${unit}`;
    }
    return {
      configured: true,
      title: value.title,
      number,
      unit,
      summary,
      date: target.map((p, i) => (i ? String(p).padStart(2, "0") : String(p))).join("-"),
      accent: value.accent,
      repeatYearly: value.repeatYearly,
    };
  }
  return { configuration, describe };
})();
