// Live selected Photos sources on iPhone, iPad and Mac; browser samples only.
// In ScriptWidget Settings → Photos, authorize and select photos/albums.
// Open the installed widget in ScriptWidget to prepare its private snapshot.
// Shows one of up to four selected photos, and the next one every six hours.
// Try other texts and colors, or another photo height.
// $photos runs on iPhone, iPad and Mac, and on Android for individual photos picked in
// the app (no albums); not on Windows or Linux. widget.json must declare the permission
// "photos"; its "timeline" plans an entry at 00:00, 06:00, 12:00 and 18:00.

// $getenv("widget-size") is the size being drawn: "small", "medium", "large",
// "extraLarge", or a Lock Screen size whose name starts with "accessory".
const family = $getenv("widget-size");
const accessory = family.startsWith("accessory");
const small = family === "small" || family === "systemSmall";
const dark = $device.isdarkmode();
const background = accessory ? "clear" : dark ? "#162522" : "#eff7f3";
const foreground = accessory ? "primary" : dark ? "#e7f2eb" : "#204039";
// Read the data. `message` says what to do when there is no photo.
let photos = [],
  message = "",
  partial = false;
try {
  if (!$photos.isAvailable() || !["authorized", "limited"].includes($photos.authorizationStatus()))
    message = "Connect Photos in ScriptWidget Settings.";
  else {
    // Up to 4 photos (limit) from a snapshot at most one hour old (maxAgeSeconds).
    const result = await $photos.items({ limit: 4, maxAgeSeconds: 3600 });
    photos = result.items;
    // unavailableCount counts selected photos whose picture is not on this device.
    partial = result.unavailableCount > 0;
    if (!photos.length)
      message = partial
        ? "Download selected photos in Photos first."
        : "No photos in the selected sources.";
  }
} catch (error) {
  // A failed call throws an error whose text contains a code such as cache_miss.
  message = String(error).includes("cache_miss")
    ? "Open this widget in ScriptWidget to prepare photos."
    : "Choose photos or albums in ScriptWidget Settings.";
}
// A two-line form of the message for the small widget.
const compactMessage = message.includes("Download")
  ? "Download in Photos\nthen refresh here."
  : message.includes("prepare")
    ? "Open in ScriptWidget\nto prepare photos."
    : "Choose photos in\nSettings → Photos";
// "timeline-date" is the time this entry is planned for. It is used instead of the
// current time because the system may draw an entry ahead of its time.
const date = new Date($getenv("timeline-date") || Date.now());
// The height of the photo in points, by size.
const photoHeight =
  family === "small" || family === "medium" ? 112 : family === "extraLargePortrait" ? 480 : 290;
// Hours 0 to 5 show the first photo, 6 to 11 the second, and so on, starting over at the end.
const photo = photos.length ? photos[Math.floor(date.getHours() / 6) % photos.length] : null;
if (family === "accessoryInline") {
  // Lock Screen, inline: one line of text.
  $render(<text>{photo ? "My moments" : "Set up Photos"}</text>);
} else if (family === "accessoryCircular") {
  // Lock Screen, circular: the number of photos.
  $render(
    <vstack spacing="2">
      <icon systemName="photo" size="20" />
      <text font="caption">{photos.length ? `${photos.length} photos` : "Set up"}</text>
    </vstack>,
  );
} else if (accessory) {
  // Lock Screen, rectangular: two lines.
  $render(
    <vstack alignment="leading" spacing="4">
      <text font="headline">My moments</text>
      <text font="caption">
        {photo ? `${photos.length} selected photos` : "Open ScriptWidget to connect Photos."}
      </text>
    </vstack>,
  );
} else if (photo) {
  // A photo. `photo.image` is the picture as a data URL.
  // mode="fill" with clip="rect" crops it to the frame.
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
  // No photo: a card that says why. <link> opens its url when the card is tapped.
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
