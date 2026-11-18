// Identical package-local helper in the built-in record templates.
// Rendering is read-only. Keep at most 366 local calendar days; no network/iCloud sync.
// main.jsx imports this file ("lib/records.js") and then uses `localRecords`.
// It keeps one value per calendar day in $storage (permission "storage" in widget.json)
// and reads the settings saved by Records & Configuration in the app.
var localRecords = (() => {
  // Day key in local time, for example "2026-03-08".
  const keyFor = (date) =>
    `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
  // The same calendar day shifted by `days`, at noon so daylight saving time cannot move it.
  const offset = (date, days) =>
    new Date(date.getFullYear(), date.getMonth(), date.getDate() + days, 12);
  // True for a real calendar date written as YYYY-MM-DD (2026-02-31 is rejected).
  const validDate = (key) => {
    if (typeof key !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(key)) return false;
    const parts = key.split("-").map(Number);
    return parts[0] >= 1970 && keyFor(new Date(parts[0], parts[1] - 1, parts[2], 12)) === key;
  };
  // A deep copy, so a caller cannot change the saved state by accident.
  const clone = (value) => JSON.parse(JSON.stringify(value));
  // create(key, validValue, empty) returns the record log stored under `key`.
  // validValue(value) says whether a day's value is acceptable; `empty` is the value of a
  // day without a record; `at` is the current time.
  function create(key, validValue, empty, at = new Date()) {
    const now = offset(at, 0),
      today = keyFor(now),
      oldest = keyFor(offset(now, -365));
    const invalid = () => {
      throw new Error("Saved history is invalid. Restore your records before making changes.");
    };
    // Turn the saved text into { version, revision, entries: [{ date, value }], undo },
    // or throw if anything about it is unexpected.
    function parse(raw) {
      // Nothing saved yet: start with an empty history.
      if (raw === "") return { version: 1, revision: 0, entries: [], undo: null };
      if (typeof raw !== "string" || raw.length > 64000) return invalid();
      let state;
      try {
        state = JSON.parse(raw);
      } catch (_) {
        return invalid();
      }
      // Exactly the four expected keys, and at most 366 days.
      if (
        !state ||
        state.version !== 1 ||
        !Number.isSafeInteger(state.revision) ||
        state.revision < 0 ||
        Object.keys(state).sort().join(",") !== "entries,revision,undo,version" ||
        !Array.isArray(state.entries) ||
        state.entries.length > 366
      )
        return invalid();
      const dates = new Set();
      // Every entry is { date, value } with a real, unique date and an acceptable value.
      for (const entry of state.entries) {
        if (
          !entry ||
          Object.keys(entry).sort().join(",") !== "date,value" ||
          !validDate(entry.date) ||
          dates.has(entry.date) ||
          !validValue(entry.value)
        )
          return invalid();
        dates.add(entry.date);
      }
      // `undo` is null, or the { date, value } that the last change replaced (null = no record).
      if (
        state.undo !== null &&
        (!state.undo ||
          Object.keys(state.undo).sort().join(",") !== "date,value" ||
          !validDate(state.undo.date) ||
          (state.undo.value !== null && !validValue(state.undo.value)))
      )
        return invalid();
      return state;
    }
    // $storage.getString returns "" when nothing was saved under the key.
    const read = () => parse($storage.getString(key));
    // The value recorded on `date` (today by default), or a copy of `empty`.
    const value = (state, date = today) => {
      const entry = state.entries.find((item) => item.date === date);
      return entry ? clone(entry.value) : clone(empty);
    };
    // Save a change. transform(state) returns the new state, or null for "nothing to save".
    // compareAndSetString writes only if the stored text is still `raw`; if the app or
    // another widget saved in between, read again and retry, up to 4 times.
    function commit(transform) {
      for (let attempt = 0; attempt < 4; attempt++) {
        const raw = $storage.getString(key),
          state = parse(raw);
        const next = transform(clone(state));
        if (next === null) return false;
        if (state.revision >= Number.MAX_SAFE_INTEGER) return invalid();
        next.revision = state.revision + 1;
        // Drop days older than 365 days and keep the entries sorted by date.
        next.entries = next.entries
          .filter((entry) => entry.date >= oldest)
          .sort((a, b) => a.date.localeCompare(b.date));
        if (next.entries.length > 366)
          throw new Error("History is full. Export records before adding another date.");
        const encoded = JSON.stringify(next);
        if (encoded.length > 64000)
          throw new Error("History is full. Export records before adding more data.");
        if ($storage.compareAndSetString(key, raw, encoded)) return true;
      }
      throw new Error("Could not save. Storage is busy or unavailable; please try again.");
    }
    // Replace today's value with update(currentValue). Returning null removes today's record.
    const edit = (update) =>
      commit((state) => {
        const old = state.entries.find((entry) => entry.date === today);
        const next = update(value(state));
        if (next !== null && !validValue(next)) throw new Error("Invalid record value.");
        // Nothing changed: do not save, and keep the undo step as it is.
        if ((old && JSON.stringify(old.value) === JSON.stringify(next)) || (!old && next === null))
          return null;
        // Remember what today looked like, so undo() can put it back.
        state.undo = { date: today, value: old ? old.value : null };
        state.entries = state.entries.filter((entry) => entry.date !== today);
        if (next !== null) state.entries.push({ date: today, value: next });
        return state;
      });
    // Put back what the last edit replaced. Only one step can be undone.
    const undo = () =>
      commit((state) => {
        if (!state.undo) return null;
        if (state.undo.date < oldest)
          throw new Error("The last change is outside the retained history window.");
        const previous = state.undo;
        state.entries = state.entries.filter((entry) => entry.date !== previous.date);
        if (previous.value !== null) state.entries.push(previous);
        state.undo = null;
        return state;
      });
    // The last `count` days, oldest first: { date, value, recorded } for each.
    const recent = (state, count = 7) =>
      Array.from({ length: count }, (_, index) => {
        const date = keyFor(offset(now, index - count + 1));
        return {
          date,
          value: value(state, date),
          recorded: state.entries.some((entry) => entry.date === date),
        };
      });
    // What main.jsx can use. `today` is today's day key.
    return { today, read, value, edit, undo, reset: () => edit(() => null), recent };
  }
  // configuration(kind) returns the settings of one template. Records & Configuration saves
  // them under "recordTemplate.config.v1"; without a saved copy the defaults below apply.
  function configuration(kind) {
    const defaults = {
      plantCare: { title: "My plant", intervalDays: 3 },
      pocketPet: { title: "Pebble" },
      hydration: { goal: 8, glassML: 250 },
      mood: { intention: "Pause, breathe, and notice" },
      checklist: { items: ["Passport", "Charger", "Headphones"] },
      habitStreak: { title: "Daily habit" },
      habitHeatmap: { readName: "Read", runName: "Run", meditateName: "Meditate" },
    };
    const invalid = () => {
      throw new Error(
        "Saved template configuration is invalid. Open Records & Configuration to repair it.",
      );
    };
    if (!Object.prototype.hasOwnProperty.call(defaults, kind)) return invalid();
    const raw = $storage.getString("recordTemplate.config.v1");
    if (raw === "") return clone(defaults[kind]);
    if (typeof raw !== "string" || raw.length > 4096) return invalid();
    let state;
    try {
      // unescape(encodeURIComponent(text)).length is the size of the text in UTF-8 bytes.
      if (unescape(encodeURIComponent(raw)).length > 4096) return invalid();
      state = JSON.parse(raw);
    } catch (_) {
      return invalid();
    }
    // It must be { version: 1, kind, values }, and `values` must have the keys of the defaults.
    if (
      !state ||
      Object.keys(state).sort().join(",") !== "kind,values,version" ||
      state.version !== 1 ||
      state.kind !== kind ||
      !state.values ||
      Array.isArray(state.values) ||
      Object.keys(state.values).sort().join(",") !== Object.keys(defaults[kind]).sort().join(",")
    )
      return invalid();
    const value = state.values;
    // Two small checks: a text of at most `length` characters, a whole number in a range.
    const text = (input, length, empty = false) =>
      typeof input === "string" && input.length <= length && (empty || input.trim() !== "");
    const integer = (input, minimum, maximum) =>
      Number.isInteger(input) && input >= minimum && input <= maximum;
    let valid = false;
    // Each template has its own limits.
    if (kind === "plantCare") valid = text(value.title, 40) && integer(value.intervalDays, 1, 30);
    if (kind === "pocketPet") valid = text(value.title, 40);
    if (kind === "hydration")
      valid = integer(value.goal, 1, 32) && integer(value.glassML, 25, 2000);
    if (kind === "mood") valid = text(value.intention, 80, true);
    if (kind === "habitStreak") valid = text(value.title, 40);
    if (kind === "habitHeatmap")
      valid = ["readName", "runName", "meditateName"].every((key) => text(value[key], 40));
    if (kind === "checklist")
      valid =
        Array.isArray(value.items) &&
        value.items.length >= 1 &&
        value.items.length <= 8 &&
        new Set(value.items).size === value.items.length &&
        value.items.every((item) => text(item, 60) && item === item.trim().normalize("NFC"));
    if (!valid) return invalid();
    return clone(value);
  }
  return { create, configuration };
})();
