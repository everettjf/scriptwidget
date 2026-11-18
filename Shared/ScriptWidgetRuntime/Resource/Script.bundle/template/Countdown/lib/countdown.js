// Calendar days use Gregorian ordinals, never elapsed 24-hour periods.
// This file is imported by main.jsx. It defines one global, CountdownCalendar,
// with two functions: configuration() reads the settings and describe() turns them into
// the texts the widget shows. It draws nothing itself.
var CountdownCalendar = (() => {
  // The settings used when nothing has been saved.
  const defaults = {
    title: "Your next moment",
    targetDate: "",
    repeatYearly: false,
    accent: "blue",
  };
  // Split "YYYY-MM-DD" into [year, month, day]. Returns null for anything that is not a
  // real calendar date, such as 2027-02-30.
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
  // true if `value` holds exactly the four settings, each with a valid value.
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
  // Build the settings. `raw` is the saved JSON text from storage ("" if nothing was
  // saved) and `parameter` is the widget's parameter. Returns { value, time }: the settings
  // and, if the parameter gave a time of day, [hour, minute, second].
  function configuration(raw, parameter) {
    let value = { ...defaults };
    // The saved text must be { kind: "countdown", version: 1, values: {…} } and at most
    // 4096 bytes; unescape(encodeURIComponent(raw)).length is its size in UTF-8 bytes.
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
    // No parameter: use the saved settings as they are.
    if (!parameter) return { value, time: null };
    // A parameter that starts with "{" is JSON; its keys replace single settings.
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
    // Otherwise the parameter is "YYYY-MM-DD Title" or "YYYY-MM-DDTHH:mm:ss Title".
    // The title is optional.
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
  // The number of days from 1970-01-01 to a date. The difference of two of these is a count
  // of calendar days that daylight-saving changes cannot disturb.
  const ordinal = ([year, month, day]) => Date.UTC(year, month - 1, day) / 86400000;
  // Turn the settings into the texts to show at the time `now`.
  function describe(settings, now) {
    const value = settings.value;
    if (!Number.isFinite(now.getTime())) throw new Error("The preview date is invalid.");
    // No date chosen yet: show a hint instead of a number.
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
      // A yearly event: find its next occurrence, today included. Looking up to 8 years ahead
      // covers February 29, which most years lack.
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
    // Days until the target: positive in the future, negative in the past, 0 today.
    const days = ordinal(target) - ordinal(today);
    const dayWord = Math.abs(days) === 1 ? "day" : "days";
    let number = String(Math.abs(days)),
      unit = days === 0 ? "Today" : `${dayWord} ${days > 0 ? "to go" : "since"}`;
    let summary = days === 0 ? "Today" : `${Math.abs(days)} ${unit}`;
    // With a time of day, count minutes instead of days.
    if (settings.time) {
      const [hour, minute, second] = settings.time;
      const date = new Date(target[0], target[1] - 1, target[2], hour, minute, second);
      // A local time skipped by a daylight-saving change comes back changed; reject it.
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
      // Round up to whole minutes, then show days, or hours and minutes, or minutes.
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
      // The target date as YYYY-MM-DD.
      date: target.map((p, i) => (i ? String(p).padStart(2, "0") : String(p))).join("-"),
      accent: value.accent,
      repeatYearly: value.repeatYearly,
    };
  }
  return { configuration, describe };
})();
