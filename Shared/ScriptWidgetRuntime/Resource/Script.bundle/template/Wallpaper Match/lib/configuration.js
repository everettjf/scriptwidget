// Package-relative native background selections; rendering never imports images or changes settings.
var wallpaperConfiguration = (() => {
  const defaults = {
    title: "My space",
    caption: "",
    content: "none",
    ink: "adaptive",
    backgrounds: [],
  };
  const families = ["small", "medium", "large", "extraLarge", "extraLargePortrait"];
  const text = (value, length) => typeof value === "string" && value.length <= length;
  const validImage = (value) =>
    typeof value === "string" &&
    /^background-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
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
  function read(raw) {
    if (raw === "") return defaults;
    let state;
    try {
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
