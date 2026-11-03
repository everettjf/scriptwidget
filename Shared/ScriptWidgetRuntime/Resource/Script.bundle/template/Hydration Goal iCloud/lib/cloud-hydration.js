// Add-only cloud log. Keeping each tap as a uniquely identified event makes
// two offline devices' additions safe to union when iCloud exposes a fork.
var cloudHydration = (() => {
  const documentName = "hydration.json";
  const maximumEvents = 512;
  const maximumJSONLength = 60 * 1024;
  const empty = () => ({version: 1, events: []});
  const keys = (value) => Object.keys(value).sort().join(",");
  const dayKey = (date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
  const validDay = (day) => {
    if (typeof day !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return false;
    const parts = day.split("-").map(Number);
    const date = new Date(Date.UTC(parts[0], parts[1] - 1, parts[2], 12));
    return parts[0] >= 1970 && date.toISOString().slice(0, 10) === day;
  };
  const validTime = (time) => {
    if (typeof time !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(time)) return false;
    const date = new Date(time);
    return !Number.isNaN(date.getTime()) && date.toISOString() === time;
  };
  const fail = () => { throw new Error("Cloud hydration history is invalid. Keep the existing revisions and repair them before recording more water."); };

  function parse(value) {
    if (value === null || value === undefined) return empty();
    if (!value || Array.isArray(value) || keys(value) !== "events,version" || value.version !== 1 ||
        !Array.isArray(value.events) || value.events.length > maximumEvents) return fail();
    const ids = new Set();
    for (const event of value.events) {
      if (!event || Array.isArray(event) || keys(event) !== "at,day,id,ml" ||
          typeof event.id !== "string" || !/^[0-9a-f]{32}$/.test(event.id) || ids.has(event.id) ||
          !validTime(event.at) || !validDay(event.day) ||
          !Number.isInteger(event.ml) || event.ml < 25 || event.ml > 2000) return fail();
      ids.add(event.id);
    }
    return {version: 1, events: value.events.slice()};
  }

  function merge(values) {
    const byID = new Map();
    for (const value of values) {
      for (const event of parse(value).events) {
        const previous = byID.get(event.id);
        if (previous && (previous.at !== event.at || previous.day !== event.day || previous.ml !== event.ml)) return fail();
        byID.set(event.id, event);
      }
    }
    const events = Array.from(byID.values()).sort((a, b) => a.at.localeCompare(b.at) || a.id.localeCompare(b.id));
    const result = {version: 1, events};
    const totals = new Map();
    for (const event of events) {
      const total = (totals.get(event.day) ?? 0) + event.ml;
      if (total > 64000) throw new Error("Conflicting additions exceed the daily record limit. The original revisions are preserved.");
      totals.set(event.day, total);
    }
    if (events.length > maximumEvents || JSON.stringify(result).length > maximumJSONLength) {
      throw new Error("Cloud hydration history is full. Copy its JSON revisions from iCloud Drive before starting a new data store.");
    }
    return result;
  }

  function fromSnapshot(snapshot) {
    if (!snapshot || typeof snapshot.revision !== "string") return fail();
    if (snapshot.state === "conflict") {
      if (!Array.isArray(snapshot.conflicts) || snapshot.conflicts.length < 2 ||
          snapshot.conflicts.some((head) => !head || typeof head.id !== "string" || !head.value)) return fail();
      return merge(snapshot.conflicts.map((head) => head.value));
    }
    if (snapshot.state !== "cached" && snapshot.state !== "pending") return fail();
    if (snapshot.value === null && snapshot.revision !== "") return fail();
    return merge([snapshot.value]);
  }

  function idFor(date) {
    const time = date.getTime().toString(16).padStart(12, "0");
    return time + Array.from({length: 20}, () => Math.floor(Math.random() * 16).toString(16)).join("");
  }

  async function read() {
    const snapshot = await $icloud.readJSON(documentName);
    return {snapshot, data: fromSnapshot(snapshot)};
  }

  async function add(ml) {
    if (!Number.isInteger(ml) || ml < 25 || ml > 2000) throw new Error("Set glassML to 25–2000.");
    const at = new Date();
    const event = {id: idFor(at), at: at.toISOString(), day: dayKey(at), ml};
    for (let attempt = 0; attempt < 3; attempt++) {
      const {snapshot, data} = await read();
      if (data.events.some((item) => item.id === event.id)) return;
      const total = data.events.filter((item) => item.day === event.day).reduce((sum, item) => sum + item.ml, 0);
      if (total > 64000 - ml) throw new Error("Today's record limit would be exceeded. Nothing was saved.");
      const next = merge([data, {version: 1, events: [event]}]);
      try {
        if (snapshot.state === "conflict") await $icloud.resolveJSON(documentName, next, snapshot.revision);
        else await $icloud.writeJSON(documentName, next, snapshot.revision);
        return;
      } catch (error) {
        if (!/staleRevision|\[icloud:conflict\]/.test(String(error))) throw error;
      }
    }
    throw new Error("Cloud records changed while saving. Please tap again.");
  }

  async function sync() {
    await $icloud.sync();
    for (let attempt = 0; attempt < 2; attempt++) {
      const {snapshot, data} = await read();
      if (snapshot.state !== "conflict") return;
      try {
        await $icloud.resolveJSON(documentName, data, snapshot.revision);
        return;
      } catch (error) {
        if (!/staleRevision/.test(String(error))) throw error;
      }
    }
    throw new Error("Cloud records changed while merging. Please sync again.");
  }

  function recent(data, count = 7, now = new Date()) {
    return Array.from({length: count}, (_, index) => {
      const date = new Date(now.getFullYear(), now.getMonth(), now.getDate() + index - count + 1, 12);
      const day = dayKey(date);
      const events = data.events.filter((event) => event.day === day);
      return {day, total: events.reduce((sum, event) => sum + event.ml, 0), recorded: events.length > 0};
    });
  }

  return {read, add, sync, recent, dayKey, fromSnapshot};
})();
