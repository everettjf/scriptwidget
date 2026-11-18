// Read-only EventKit. Package 2.0 requires permissions: ["calendar"].
// In the main app, explicitly request access when the user selects Connect:
// await $calendar.requestAuthorization();
// Widgets never present the authorization prompt.
let message = "Allow Calendar access in ScriptWidget.";
if ($calendar.isAvailable() && $calendar.authorizationStatus() === "authorized") {
  try {
    const calendars = await $calendar.calendars(); // up to 64 {id,title} entries
    const result = await $calendar.events({ limit: 5, maxAgeSeconds: 60 });
    // Optional: calendarIDs: [calendars[0].id], start/end ISO-8601 timestamps.
    // Limit: 1–50 events, 31-day window, 1–16 selected calendar IDs.
    message = result.items.map((event) => event.title).join(" · ") || "No events today";
  } catch (error) {
    message = "Calendar unavailable. Check access in the app.";
  }
}
$render(
  <vstack padding="12">
    <text>{message}</text>
  </vstack>,
);
