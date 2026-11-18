// Calendar Agenda — actual EventKit data on iPhone, iPad and Mac.
// Declare calendar in widget.json. Run in the app to grant access.
// Optional widget parameter: comma-separated calendar IDs from $calendar.calendars().
// Browser previews use editable samples; native templates never seed fake events.
const size = $getenv("widget-size");
const accessory = size.startsWith("accessory");
const dark = $device.isdarkmode();
const foreground = accessory ? "primary" : dark ? "#f3f4f6" : "#172033";
const secondary = accessory ? "secondary" : dark ? "#9ca3af" : "#68758b";
const background = accessory ? "clear" : dark ? "#131b2a" : "#f4f7fc";
const accent = accessory ? "primary" : "#5274d9";
const small = size === "small" || size === "systemSmall";
const limit = accessory || small ? 2 : size === "medium" || size === "systemMedium" ? 3 : 6;
let events = [],
  message = "",
  authorized = false,
  stale = false,
  failed = false;

try {
  if (!$calendar.isAvailable()) message = "Calendar is unavailable on this device.";
  else if ($calendar.authorizationStatus() !== "authorized")
    message = small
      ? "Settings → Calendar in ScriptWidget."
      : "Connect Calendar in ScriptWidget Settings.";
  else {
    authorized = true;
    const parameter = $getenv("widget-param").trim();
    const options = { limit, maxAgeSeconds: 60 };
    if (parameter)
      options.calendarIDs = parameter
        .split(",")
        .map((id) => id.trim())
        .filter(Boolean);
    const result = await $calendar.events(options);
    events = Array.isArray(result.items) ? result.items : [];
    stale = result.stale;
    if (!events.length) message = "Your day is clear.";
  }
} catch (error) {
  failed = true;
  message = String(error).includes("No Calendar sources")
    ? small || accessory
      ? "Choose calendars in Settings."
      : "Choose Calendar sources in ScriptWidget Settings."
    : String(error).includes("invalid_options")
      ? small || accessory
        ? "Review Calendar selection."
        : "Review your Calendar selection and widget parameter."
      : small || accessory
        ? "Open ScriptWidget to check access."
        : "Calendar could not load. Open ScriptWidget to check access.";
}

function eventTime(event) {
  if (event.allDay) return "All day";
  return new Date(event.start).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

if (size === "accessoryInline") {
  $render(
    <text>
      {events.length
        ? `${eventTime(events[0])} ${events[0].title}`
        : failed
          ? "Check Calendar access"
          : authorized
            ? "No events today"
            : "Connect Calendar"}
    </text>,
  );
} else if (size === "accessoryCircular") {
  $render(
    <vstack spacing="2">
      <icon systemName="calendar" size="20" />
      <text font="caption">
        {failed ? "Check" : authorized ? `${events.length} events` : "Connect"}
      </text>
    </vstack>,
  );
} else {
  $render(
    <vstack
      frame="max"
      padding={accessory ? "4" : "16"}
      spacing={accessory ? "4" : "10"}
      alignment="leading"
      background={background}
    >
      <hstack spacing="6">
        <icon systemName="calendar.badge.clock" size="16" color={accent} />
        <text font="caption" color={secondary}>
          {small ? "AGENDA" : "TODAY'S AGENDA"}
        </text>
        <spacer />
        {stale && (
          <text font="caption2" color={secondary}>
            Cached
          </text>
        )}
      </hstack>
      {events.map((event) => (
        <hstack spacing="10">
          <rect frame="3,30" color={accent} />
          <vstack alignment="leading" spacing="3">
            <text font={small || accessory ? "caption" : "headline"} color={foreground}>
              {event.title || "Untitled event"}
            </text>
            <text font="caption2" color={secondary}>
              {eventTime(event)}
            </text>
          </vstack>
          <spacer />
        </hstack>
      ))}
      {!!message && (
        <text font={authorized && !failed ? "headline" : "caption"} color={foreground}>
          {message}
        </text>
      )}
      {(!authorized || failed) && !accessory && (
        <link url="scriptwidget://calendar-access">
          <hstack spacing="6">
            <icon systemName="lock.open" size="14" />
            <text font="caption">{small ? "Settings" : "Open ScriptWidget"}</text>
          </hstack>
        </link>
      )}
      {!accessory && <spacer />}
    </vstack>,
  );
}
