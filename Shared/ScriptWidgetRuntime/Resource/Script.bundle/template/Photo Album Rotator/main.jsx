// Live selected Photos sources on iPhone, iPad and Mac; browser samples only.
// In ScriptWidget Settings → Photos, authorize and select photos/albums.
// Open the installed widget in ScriptWidget to prepare its private snapshot.
const family = $getenv("widget-size");
const accessory = family.startsWith("accessory");
const small = family === "small" || family === "systemSmall";
const dark = $device.isdarkmode();
const background = accessory ? "clear" : dark ? "#162522" : "#eff7f3";
const foreground = accessory ? "primary" : dark ? "#e7f2eb" : "#204039";
let photos = [],
  message = "",
  partial = false;
try {
  if (!$photos.isAvailable() || !["authorized", "limited"].includes($photos.authorizationStatus()))
    message = "Connect Photos in ScriptWidget Settings.";
  else {
    const result = await $photos.items({ limit: 4, maxAgeSeconds: 3600 });
    photos = result.items;
    partial = result.unavailableCount > 0;
    if (!photos.length)
      message = partial
        ? "Download selected photos in Photos first."
        : "No photos in the selected sources.";
  }
} catch (error) {
  message = String(error).includes("cache_miss")
    ? "Open this widget in ScriptWidget to prepare photos."
    : "Choose photos or albums in ScriptWidget Settings.";
}
const compactMessage = message.includes("Download")
  ? "Download in Photos\nthen refresh here."
  : message.includes("prepare")
    ? "Open in ScriptWidget\nto prepare photos."
    : "Choose photos in\nSettings → Photos";
const date = new Date($getenv("timeline-date") || Date.now());
const photoHeight =
  family === "small" || family === "medium" ? 112 : family === "extraLargePortrait" ? 480 : 290;
const photo = photos.length ? photos[Math.floor(date.getHours() / 6) % photos.length] : null;
if (family === "accessoryInline") {
  $render(<text>{photo ? "My moments" : "Set up Photos"}</text>);
} else if (family === "accessoryCircular") {
  $render(
    <vstack spacing="2">
      <icon systemName="photo" size="20" />
      <text font="caption">{photos.length ? `${photos.length} photos` : "Set up"}</text>
    </vstack>,
  );
} else if (accessory) {
  $render(
    <vstack alignment="leading" spacing="4">
      <text font="headline">My moments</text>
      <text font="caption">
        {photo ? `${photos.length} selected photos` : "Open ScriptWidget to connect Photos."}
      </text>
    </vstack>,
  );
} else if (photo) {
  $render(
    <vstack frame="max" spacing="0" background={background}>
      <image url={photo.image} mode="fill" frame={`max,${photoHeight}`} clip="rect" />
      <hstack padding="10">
        <text font="caption" color={foreground}>
          My moments
        </text>
        <spacer />
        {partial && <icon systemName="icloud" size="12" color={foreground} />}
      </hstack>
    </vstack>,
  );
} else {
  $render(
    <link url="scriptwidget://photos-access">
      <vstack
        frame="max"
        alignment="leading"
        spacing={small ? "6" : "8"}
        padding="14"
        background={background}
      >
        <icon systemName="photo.on.rectangle" size="22" color={foreground} />
        <text font="headline" color={foreground}>
          My moments
        </text>
        <text
          font={small ? "caption2" : "caption"}
          color={foreground}
          frame={small ? "max,32" : "max,40"}
        >
          {small ? compactMessage : message}
        </text>
        <spacer />
        <text font="caption" color={foreground}>
          {small ? "Photos settings →" : "Open Photos settings →"}
        </text>
      </vstack>
    </link>,
  );
}
