// Settings for Photo Card. main.jsx loads this file and calls
// photoCardConfiguration.read(). A file loaded this way shares its top-level names
// with main.jsx, so everything else is kept private inside one function.
var photoCardConfiguration = (() => {
  // Used when nothing has been saved yet.
  const defaults = { title: "Little moments", caption: "", layout: "single", photos: [] };
  // True when the settings have exactly the four expected keys and every value is in range:
  // a title of 1–40 characters, a caption of up to 80, a known layout, and at most four
  // different photo names of the form photo-<UUID>.
  const valid = (value) =>
    value &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    Object.keys(value).sort().join(",") === "caption,layout,photos,title" &&
    typeof value.title === "string" &&
    value.title.trim().length > 0 &&
    value.title.length <= 40 &&
    typeof value.caption === "string" &&
    value.caption.length <= 80 &&
    ["single", "duo", "grid"].includes(value.layout) &&
    Array.isArray(value.photos) &&
    value.photos.length <= 4 &&
    new Set(value.photos).size === value.photos.length &&
    value.photos.every(
      (name) =>
        typeof name === "string" &&
        /^photo-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(name),
    );
  // raw: the saved settings string ("" when nothing is saved). parameter: the widget
  // parameter. Returns the settings to draw with, or throws an error for the widget to show.
  function read(raw, parameter) {
    let values = { ...defaults, photos: [] };
    // Saved settings look like {"version":1,"kind":"photoCard","values":{…}}. Anything else
    // is refused instead of being guessed at.
    if (raw !== "") {
      let state;
      try {
        state = JSON.parse(raw);
      } catch (_) {
        throw new Error(
          "Saved photo settings are invalid. Open Records & Configuration to repair them.",
        );
      }
      // unescape(encodeURIComponent(raw)).length is the size in UTF-8 bytes; the limit is 4096.
      if (
        typeof raw !== "string" ||
        unescape(encodeURIComponent(raw)).length > 4096 ||
        !state ||
        Object.keys(state).sort().join(",") !== "kind,values,version" ||
        state.version !== 1 ||
        state.kind !== "photoCard" ||
        !valid(state.values)
      )
        throw new Error(
          "Saved photo settings are invalid. Open Records & Configuration to repair them.",
        );
      values = state.values;
    }
    // The widget parameter may override some settings for one widget. Unknown keys are refused.
    if ((parameter || "").trim()) {
      let overrides;
      try {
        overrides = JSON.parse(parameter);
      } catch (_) {
        throw new Error("Photo Card parameters must be a JSON object.");
      }
      if (
        !overrides ||
        Array.isArray(overrides) ||
        Object.keys(overrides).some((key) => !Object.prototype.hasOwnProperty.call(defaults, key))
      )
        throw new Error("Photo Card accepts title, caption, layout and photos only.");
      values = { ...values, ...overrides };
    }
    // Check the merged result too, because the parameter is typed by hand.
    if (!valid(values))
      throw new Error(
        "Choose up to 4 imported photos, a single/duo/grid layout and valid title/caption text.",
      );
    return values;
  }
  return { read };
})();
