var quickLauncher = (() => {
  const icons = [
    "globe",
    "map.fill",
    "play.fill",
    "star.fill",
    "music.note",
    "envelope.fill",
    "phone.fill",
    "message.fill",
    "house.fill",
    "checkmark.circle.fill",
  ];
  const defaults = {
    title: "Quick Launch",
    accent: "blue",
    items: [
      {
        id: "github",
        title: "GitHub",
        icon: "globe",
        type: "web",
        target: "https://github.com",
        input: "",
      },
      { id: "maps", title: "Maps", icon: "map.fill", type: "app", target: "maps://", input: "" },
      {
        id: "search",
        title: "Search",
        icon: "star.fill",
        type: "web",
        target: "https://www.google.com",
        input: "",
      },
    ],
  };
  const closed = (value, keys) =>
    value &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    Object.keys(value).sort().join(",") === keys.split(",").sort().join(",");
  const plain = (value, max) =>
    typeof value === "string" &&
    value.length <= max &&
    value.trim().length > 0 &&
    !/[\p{Cc}\p{Cf}]/u.test(value);
  const encode = (value) =>
    encodeURIComponent(value).replace(
      /[!'()*]/g,
      (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase(),
    );
  function destination(item) {
    if (
      !closed(item, "id,title,icon,type,target,input") ||
      typeof item.id !== "string" ||
      !/^[A-Za-z0-9][A-Za-z0-9-]{0,39}$/.test(item.id) ||
      !plain(item.title, 24) ||
      !icons.includes(item.icon) ||
      !["web", "app", "shortcut"].includes(item.type) ||
      typeof item.input !== "string" ||
      item.input.length > 500 ||
      item.input.includes("\u0000")
    )
      throw new Error("Invalid launcher item. Open Records & Configuration.");
    if (item.type === "shortcut") {
      if (!plain(item.target, 128)) throw new Error("Enter the name of a saved shortcut.");
      return (
        "shortcuts://run-shortcut?name=" +
        encode(item.target) +
        (item.input ? "&input=text&text=" + encode(item.input) : "")
      );
    }
    if (
      item.input !== "" ||
      !plain(item.target, 2048) ||
      /[\s\\]/u.test(item.target) ||
      /%(?![0-9a-f]{2})/i.test(item.target)
    )
      throw new Error("Enter a valid URL without spaces or credentials.");
    const match = /^([A-Za-z][A-Za-z0-9+.-]*):/.exec(item.target);
    if (!match) throw new Error("An absolute URL is required.");
    const scheme = match[1].toLowerCase(),
      authority = item.target.slice(match[0].length).startsWith("//")
        ? item.target.slice(match[0].length + 2).split(/[/?#]/)[0]
        : "";
    if (authority.includes("@")) throw new Error("URL credentials are not supported.");
    if (item.type === "web") {
      const web =
        /^https?:\/\/(?:[A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(?::([0-9]{1,5}))?(?:[/?#]|$)/i.exec(
          item.target,
        );
      if (!web || (web[1] !== undefined && (Number(web[1]) < 1 || Number(web[1]) > 65535)))
        throw new Error("Use an HTTP(S) web link.");
    } else if (
      [
        "http",
        "https",
        "file",
        "data",
        "javascript",
        "about",
        "blob",
        "widget-deeplink",
        "scriptwidget",
        "prefs",
        "app-prefs",
      ].includes(scheme)
    )
      throw new Error("Use an external app URL scheme.");
    return item.target;
  }
  function validate(value) {
    if (
      !closed(value, "title,accent,items") ||
      !plain(value.title, 40) ||
      !["blue", "green", "rose"].includes(value.accent) ||
      !Array.isArray(value.items) ||
      value.items.length < 1 ||
      value.items.length > 6 ||
      new Set(value.items.map((item) => item?.id)).size !== value.items.length
    )
      throw new Error("Configure a title, accent and 1–6 unique launcher links.");
    value.items.forEach(destination);
    if (
      unescape(encodeURIComponent(JSON.stringify({ version: 1, kind: "launcher", values: value })))
        .length > 32768
    )
      throw new Error("Launcher configuration exceeds 32 KiB.");
    return value;
  }
  function options(raw, parameter) {
    let result = { ...defaults, items: defaults.items.map((item) => ({ ...item })) };
    if (raw !== null && raw !== undefined && raw !== "") {
      if (typeof raw !== "string" || raw.length > 32768)
        throw new Error("Invalid launcher configuration.");
      const saved = JSON.parse(raw);
      if (!closed(saved, "version,kind,values") || saved.version !== 1 || saved.kind !== "launcher")
        throw new Error("Invalid launcher configuration.");
      result = validate(saved.values);
    }
    if (parameter) {
      if (typeof parameter !== "string" || parameter.length > 32768)
        throw new Error("Invalid launcher parameter.");
      const overrides = JSON.parse(parameter);
      if (
        !overrides ||
        typeof overrides !== "object" ||
        Array.isArray(overrides) ||
        Object.keys(overrides).some((key) => !Object.hasOwn(defaults, key))
      )
        throw new Error("Unknown launcher setting.");
      result = { ...result, ...overrides };
    }
    validate(result);
    return { ...result, items: result.items.map((item) => ({ ...item, url: destination(item) })) };
  }
  return { options, destination };
})();
