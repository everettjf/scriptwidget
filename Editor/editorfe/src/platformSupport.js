// Which systems each global API runs on. One row per API (or group of APIs
// with the same answer). `true` is "Yes", `false` is "No", a string is "Yes"
// with that limit, written as the cell's text.
//
// This file is the source of the tables that `npm run docs` writes into
// docs/platform-support.md, docs/runtime-api.md, docs/data-api-catalog.md and
// the per-API pages. The authorities for each column are named in
// docs/platform-support.md; change this file when one of them changes.
//
// The iPhone/iPad and Mac columns of the data APIs must agree with the
// `platforms` of dataAPICatalog.js; the generator refuses to run otherwise.

export const platformColumns = [
  { id: "ios", title: "iPhone and iPad" },
  { id: "macos", title: "Mac" },
  { id: "android", title: "Android" },
  { id: "windows", title: "Windows" },
  { id: "linux", title: "Linux" },
];

const everywhere = { ios: true, macos: true, android: true, windows: true, linux: true };
const appleOnly = { android: false, windows: false, linux: false };

export const platformSupport = [
  { apis: ["$device", "$system", "$storage", "$file", "fetch", "$http", "$xml"], ...everywhere },
  { apis: ["$dataSource"], label: "`$dataSource` (Data Source Plugins)", ...everywhere },
  { apis: ["$weather"], ...everywhere },
  { apis: ["$calendar"], ios: true, macos: true, android: "Yes, for calendars selected in the app", windows: false, linux: false },
  { apis: ["$photos"], ios: true, macos: true, android: "Individual photos picked in the app, no albums", windows: false, linux: "Pictures picked for the widget in the management window, no albums" },
  { apis: ["$contacts"], ios: true, macos: true, android: "Yes, for contacts picked in the app", windows: false, linux: false },
  { apis: ["$documents"], ios: true, macos: true, android: "Yes, for files picked in the app", windows: false, linux: "Files picked for the widget in the management window" },
  { apis: ["$maps"], ios: true, macos: true, android: "Geocoding and place search; no `snapshot`", windows: false, linux: false },
  { apis: ["$notifications"], ios: true, macos: true, android: "Yes, delivery is inexact", windows: false, linux: "Yes, shown by the background service; delivery is inexact" },
  { apis: ["$services"], label: "`$services` (GitHub)", ios: true, macos: true, android: "With a fine-grained token, no OAuth sign-in", windows: false, linux: "With a fine-grained token kept in the system keyring, no OAuth sign-in" },
  { apis: ["$icloud"], ios: true, macos: true, android: "A sync folder the user picks; cannot exchange data with an iPhone", windows: false, linux: false },
  { apis: ["$location"], ios: true, macos: false, android: "Yes; widgets see the position saved while the app was open", windows: false, linux: false },
  { apis: ["$health"], ios: true, macos: false, android: "Health Connect; no ring goals or stand time", windows: false, linux: false },
  { apis: ["$music"], ios: true, macos: false, android: "The active media session of any app", windows: false, linux: "The active MPRIS player, read only" },
  { apis: ["$alarms"], ios: true, macos: false, android: "Yes, inexact, no system alarm UI", windows: false, linux: false },
  { apis: ["$reminders"], ios: true, macos: true, ...appleOnly },
  { apis: ["$home"], ios: true, macos: false, ...appleOnly },
];

export function platformRow(api) {
  return platformSupport.find((row) => row.apis.includes(api));
}

export function platformCell(value) {
  return value === true ? "Yes" : value === false ? "No" : value;
}

// "iPhone and iPad, Mac, Android (…)" and "Windows, Linux" for one row.
export function platformSentence(row) {
  const yes = [], no = [];
  for (const column of platformColumns) {
    const value = row[column.id];
    if (value === false) no.push(column.title);
    else yes.push(value === true ? column.title : `${column.title} (${value.replace(/^Yes[,;] /, "")})`);
  }
  return { yes: yes.join(", "), no: no.join(", ") };
}

// The same for the JSX components. Android, Windows and Linux draw with one
// shared renderer, so a component exists on all three or on none; what differs
// is listed here. The authorities are docs/public-animations.md for the Apple
// columns and the "Differences" tables of docs/android, docs/windows and
// docs/linux for the others.
const lookAlike = "Yes; SF Symbols are drawn with look-alike icons, and a name without one shows a placeholder";
export const componentSupport = [
  { components: ["<vstack>", "<hstack>", "<zstack>", "<vgrid>", "<hgrid>", "<spacer>", "<divider>"], label: "Layout: `<vstack>`, `<hstack>`, `<zstack>`, `<vgrid>`, `<hgrid>`, `<spacer>`, `<divider>`", ...everywhere },
  { components: ["<text>", "<label>", "<badge>", "<chip>", "<stat>"], label: "Text: `<text>`, `<label>`, `<badge>`, `<chip>`, `<stat>`", ios: true, macos: true, android: "Yes, in Inter, which is wider than the Apple system font", windows: "Yes, in Inter", linux: "Yes, in Inter" },
  { components: ["<rect>", "<roundedrect>", "<capsule>", "<ellipse>", "<circle>", "<line>"], label: "Shapes: `<rect>`, `<roundedrect>`, `<capsule>`, `<ellipse>`, `<circle>`, `<line>`", ...everywhere },
  { components: ["<gauge>", "<progress>", "<ring>", "<chart>"], label: "Values: `<gauge>`, `<progress>`, `<ring>`, `<chart>`", ...everywhere },
  { components: ["<image>"], ...everywhere },
  { components: ["<icon>"], label: "`<icon>` and `systemName` images", ios: true, macos: true, android: lookAlike, windows: lookAlike, linux: lookAlike },
  { components: ["<date>"], ios: true, macos: true, android: "`timer` and a `time` of now tick by themselves; `relative`, `offset` and `date` are redrawn at each refresh", windows: "A timer is redrawn every second and a clock time every minute", linux: "A timer is redrawn every second and a clock time every minute" },
  { components: ["<gif>"], ios: "Animated in the app's preview; in a widget the system decides and may hold one frame", macos: "The first frame", android: "Up to 24 sampled frames", windows: "The first frame", linux: "Animated on the desktop, at most 60 frames" },
  { components: ["animation"], label: "The `animation` property (clock hands, swing)", ios: "Moves in the app's preview; in a widget the system schedules it and may hold one frame", macos: "Standard clock hands show the time without moving; the others stay at rest", android: "Standard clock hands are a system clock; swing and custom intervals play as frames", windows: "The first frame", linux: "Moves on the desktop: clock hands follow the time, swings and custom intervals play at up to 20 frames a second; `render` and the previews show one frame" },
  { components: ["<button>", "<toggle>"], ios: "Yes, from iOS 17", macos: "Yes, from macOS 14", android: true, windows: true, linux: true },
  { components: ["<link>"], ios: true, macos: true, android: true, windows: "`http`, `https` and `mailto` only", linux: "`http`, `https` and `mailto` only" },
  { components: ["backgroundMaterial"], label: "The `backgroundMaterial` property", ios: true, macos: true, android: "The opaque `background` fallback", windows: "The opaque `background` fallback", linux: "The opaque `background` fallback" },
  { components: ["<list>"], label: "Scrolling `<list>`", ios: "Draws the rows that fit; no scrolling", macos: "Draws the rows that fit; no scrolling", android: true, windows: "Drawn in place and cut off at its bottom edge; no scrolling", linux: "Drawn in place and cut off at its bottom edge; no scrolling" },
  { components: ["material.<role>"], label: "Wallpaper colors (`material.<role>`)", ios: "A fixed palette", macos: "A fixed palette", android: true, windows: "A fixed palette", linux: "A fixed palette" },
];
