var photoCardConfiguration = (() => {
  const defaults = { title: "Little moments", caption: "", layout: "single", photos: [] };
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
  function read(raw, parameter) {
    let values = { ...defaults, photos: [] };
    if (raw !== "") {
      let state;
      try {
        state = JSON.parse(raw);
      } catch (_) {
        throw new Error(
          "Saved photo settings are invalid. Open Records & Configuration to repair them.",
        );
      }
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
    if (!valid(values))
      throw new Error(
        "Choose up to 4 imported photos, a single/duo/grid layout and valid title/caption text.",
      );
    return values;
  }
  return { read };
})();
