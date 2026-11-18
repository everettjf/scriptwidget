// Package-relative native background selections; rendering never imports images or changes settings.
//
// Settings for Wallpaper Match. main.jsx loads this file and calls
// wallpaperConfiguration.load().
var wallpaperConfiguration = (() => {
  // Used when nothing has been saved. content is "none", "text" or "date"; ink is the
  // text color: "adaptive" (follows dark mode), "light" or "dark".
  const defaults = {
    title: "My space",
    caption: "",
    content: "none",
    ink: "adaptive",
    backgrounds: [],
  };
  // The widget sizes that can have a background.
  const families = ["small", "medium", "large", "extraLarge", "extraLargePortrait"];
  const text = (value, length) => typeof value === "string" && value.length <= length;
  // An image name has the form background-<UUID>; its file is image/<name>.png.
  const validImage = (value) =>
    typeof value === "string" &&
    /^background-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
  // True when the settings have exactly the expected keys and every value is in range.
  function validate(value) {
    if (
      !value ||
      typeof value !== "object" ||
      Array.isArray(value) ||
      Object.keys(value).sort().join(",") !== "backgrounds,caption,content,ink,title" ||
      !text(value.title, 40) ||
      !text(value.caption, 80) ||
      !["none", "text", "date"].includes(value.content) ||
      !["adaptive", "light", "dark"].includes(value.ink) ||
      !Array.isArray(value.backgrounds) ||
      value.backgrounds.length > 10
    )
      return false;
    // Each background is one image for one size and one appearance; a pair may appear once.
    const seen = new Set();
    return value.backgrounds.every((asset) => {
      if (
        !asset ||
        typeof asset !== "object" ||
        Array.isArray(asset) ||
        Object.keys(asset).sort().join(",") !== "appearance,family,image,label" ||
        !families.includes(asset.family) ||
        !["light", "dark"].includes(asset.appearance) ||
        !validImage(asset.image) ||
        !text(asset.label, 30) ||
        !asset.label.trim() ||
        /[\p{Cc}\p{Cf}]/u.test(asset.label)
      )
        return false;
      const key = asset.family + "." + asset.appearance;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  }
  // Parses a settings string of the form { version: 1, kind: "wallpaper", values }.
  // Damaged settings throw an error instead of being replaced by the defaults.
  function read(raw) {
    if (raw === "") return defaults;
    let state;
    try {
      // At most 4096 bytes of UTF-8.
      if (typeof raw !== "string" || unescape(encodeURIComponent(raw)).length > 4096)
        throw new Error();
      state = JSON.parse(raw);
    } catch (_) {
      throw new Error(
        "Saved background settings are invalid. Open Records & Configuration to repair them.",
      );
    }
    if (
      !state ||
      Object.keys(state).sort().join(",") !== "kind,values,version" ||
      state.version !== 1 ||
      state.kind !== "wallpaper" ||
      !validate(state.values)
    )
      throw new Error(
        "Saved background settings are invalid. Open Records & Configuration to repair them.",
      );
    return state.values;
  }
  // The settings saved in $storage come first; without them the optional file
  // wallpaper.json of the package is used, and without that the defaults.
  function load() {
    const saved = $storage.getString("recordTemplate.config.v1");
    if (saved !== "") return read(saved);
    if (!$file.exists("wallpaper.json")) return defaults;
    const portable = $file.read("wallpaper.json");
    if (portable === "")
      throw new Error(
        "wallpaper.json is empty or unavailable. Restore or repair the package settings.",
      );
    return read(portable);
  }
  return { read, validate, load };
})();
