// Import and calibrate your own background in Records & Configuration.
// Crops match one Home Screen size, position and light/dark appearance.
//
// This template shows a full-size image behind text, chosen by widget size and by light
// or dark mode. Try changing the fonts, or the texts shown while no image is set.

// $import runs lib/configuration.js from this package and returns false when that fails.
// The file defines wallpaperConfiguration.
if (!$import("lib/configuration.js"))
  throw new Error("Install the complete Wallpaper Match template.");
// The saved settings: title, caption, what to show, text color and the list of crops.
const options = wallpaperConfiguration.load();
// The size being drawn ("small", "medium", …) and the current appearance.
const family = $getenv("widget-size"),
  appearance = $device.isdarkmode() ? "dark" : "light";
// Text color: white or near-black, as set in the settings or following dark mode.
const color =
  options.ink === "light" || (options.ink === "adaptive" && appearance === "dark")
    ? "#ffffff"
    : "#111827";
// "timeline-date" is the moment this entry is drawn for, which is later than now when the
// system prepares the widget in advance.
const referenceDate = new Date($getenv("timeline-date") || Date.now());
if (family === "accessoryInline") {
  // Lock Screen sizes (iPhone and iPad only) have no background image: a text or the date.
  $render(
    options.content === "date" ? (
      <date date={referenceDate.getTime()} style="date" />
    ) : (
      <text>{options.title || "Wallpaper Match"}</text>
    ),
  );
} else if (family === "accessoryCircular") {
  $render(
    <vstack spacing="2">
      <icon systemName="photo" />
      <text font="caption2">
        {options.content === "date" ? String(referenceDate.getDate()) : "Match"}
      </text>
    </vstack>,
  );
} else if (family === "accessoryRectangular") {
  $render(
    <vstack alignment="leading" spacing="3">
      <text font="headline">{options.title || "Wallpaper Match"}</text>
      {options.content === "date" ? (
        <date date={referenceDate.getTime()} style="date" font="caption" />
      ) : (
        <text font="caption">{options.caption || "Backgrounds apply on the Home Screen"}</text>
      )}
    </vstack>,
  );
} else {
  // Home Screen sizes: find the crop saved for this size and appearance.
  const asset = options.backgrounds.find(
    (item) => item.family === family && item.appearance === appearance,
  );
  // $file.exists checks for a file inside this package; a crop is stored as image/<name>.png.
  const available = asset && $file.exists("image/" + asset.image + ".png");
  if (!available) {
    // No crop, or its file is gone: say what to do. frame="max" fills the widget; padding
    // is the space around the content, in points.
    $render(
      <vstack
        frame="max"
        padding="14"
        spacing="8"
        background={appearance === "dark" ? "#1e293b" : "#f1f5f9"}
      >
        <icon systemName="photo.on.rectangle" size="26" />
        <text font="headline">{asset ? "Restore this crop" : "Match your wallpaper"}</text>
        <text font="caption2">
          {asset
            ? "The selected image file is unavailable."
            : `Add a ${appearance} crop for this size in Records & Configuration.`}
        </text>
      </vstack>,
    );
  } else {
    // The image fills the widget and the text lies over it in a <zstack>.
    $render(
      <zstack frame="max">
        {/* mode="fill" covers the whole frame and clip="rect" cuts off what sticks out. */}
        {/* accentedRenderingMode="fullColor" keeps the colors in tinted widget appearances. */}
        <image
          name={asset.image}
          mode="fill"
          frame="max"
          clip="rect"
          accentedRenderingMode="fullColor"
        />
        {options.content !== "none" && (
          <vstack frame="max" alignment="leading" padding="16" spacing="7">
            {options.content === "date" && (
              <date
                date={referenceDate.getTime()}
                style="date"
                font={family === "small" ? "caption" : "title2"}
                color={color}
              />
            )}
            {/* The small widget cuts long texts: 16 characters of title, 24 of caption. */}
            {options.title && (
              <text font="headline" color={color}>
                {family === "small"
                  ? Array.from(options.title.replace(/\s+/g, " ")).slice(0, 16).join("")
                  : options.title}
              </text>
            )}
            {options.caption && (
              <text font="caption" color={color}>
                {family === "small"
                  ? Array.from(options.caption.replace(/\s+/g, " ")).slice(0, 24).join("")
                  : options.caption}
              </text>
            )}
          </vstack>
        )}
      </zstack>,
    );
  }
}
