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
  { apis: ["$photos"], ios: true, macos: true, android: "Individual photos picked in the app, no albums", windows: false, linux: false },
  { apis: ["$contacts", "$documents"], ios: true, macos: true, android: "Yes, for items picked in the app", windows: false, linux: false },
  { apis: ["$maps"], ios: true, macos: true, android: "Geocoding and place search; no `snapshot`", windows: false, linux: false },
  { apis: ["$notifications"], ios: true, macos: true, android: "Yes, delivery is inexact", windows: false, linux: false },
  { apis: ["$services"], label: "`$services` (GitHub)", ios: true, macos: true, android: "With a fine-grained token, no OAuth sign-in", windows: false, linux: false },
  { apis: ["$icloud"], ios: true, macos: true, android: "A sync folder the user picks; cannot exchange data with an iPhone", windows: false, linux: false },
  { apis: ["$location"], ios: true, macos: false, android: "Yes; widgets see the position saved while the app was open", windows: false, linux: false },
  { apis: ["$health"], ios: true, macos: false, android: "Health Connect; no ring goals or stand time", windows: false, linux: false },
  { apis: ["$music"], ios: true, macos: false, android: "The active media session of any app", windows: false, linux: false },
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
