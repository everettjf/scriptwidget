// Calendar Agenda — actual EventKit data on iPhone, iPad and Mac.
// Declare calendar in widget.json. Run in the app to grant access.
// Optional widget parameter: comma-separated calendar IDs from $calendar.calendars().
// Browser previews use editable samples; native templates never seed fake events.
// $calendar runs on iPhone and iPad, Mac and Android (for calendars selected in the app);
// not on Windows or Linux.
// Shows today's events, with a layout for each size and a message for each way the read
// can fail. Try changing `limit` or the colors.
//
// The size being drawn. The "accessory" sizes are Lock Screen widgets: for them the colors
// are "primary" and "secondary" instead of fixed values, and the background is clear.
const size = $getenv("widget-size");
const accessory = size.startsWith("accessory");
const dark = $device.isdarkmode();
const foreground = accessory ? "primary" : dark ? "#f3f4f6" : "#172033";
const secondary = accessory ? "secondary" : dark ? "#9ca3af" : "#5f6c81";
const background = accessory ? "clear" : dark ? "#131b2a" : "#f4f7fc";
const accent = accessory ? "primary" : "#5274d9";
const small = size === "small" || size === "systemSmall";
// How many events to ask for: 2 on small and Lock Screen sizes, 3 on medium, 6 on larger.
const limit = accessory || small ? 2 : size === "medium" || size === "systemMedium" ? 3 : 6;
// What the read below finds. `message` is shown under, or instead of, the event list.
let events = [],
  message = "",
  authorized = false,
  stale = false,
  failed = false;

// Read the data. Each way it can go wrong sets a message instead of stopping the script.
try {
  // isAvailable() is false on a system without $calendar. authorizationStatus() tells
  // whether calendar access has been allowed in the ScriptWidget app.
  if (!$calendar.isAvailable()) message = "Calendar is unavailable on this device.";
  else if ($calendar.authorizationStatus() !== "authorized")
    message = small
      ? "Settings → Calendar in ScriptWidget."
      : "Connect Calendar in ScriptWidget Settings.";
  else {
    authorized = true;
    const parameter = $getenv("widget-param").trim();
    // Ask for today's events, at most `limit`. A saved answer up to 60 seconds old may be used.
    const options = { limit, maxAgeSeconds: 60 };
    // The optional parameter narrows the read to the listed calendar IDs.
    if (parameter)
      options.calendarIDs = parameter
        .split(",")
        .map((id) => id.trim())
        .filter(Boolean);
    const result = await $calendar.events(options);
    // result.items is the list of events. result.stale is true for an older saved answer.
    events = Array.isArray(result.items) ? result.items : [];
    stale = result.stale;
    if (!events.length) message = "Your day is clear.";
  }
} catch (error) {
  // The read was rejected. Choose a short message for small sizes, a longer one otherwise.
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

// "All day", or the start time in the device's own format. event.start is an ISO-8601
// date string.
function eventTime(event) {
  if (event.allDay) return "All day";
  return new Date(event.start).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

// Choose a layout for the widget size.
if (size === "accessoryInline") {
  // Lock Screen line: the first event, or the reason there is none.
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
  // Lock Screen circle: an icon and the number of events.
  $render(
    <vstack spacing="2">
      <icon systemName="calendar" size="20" />
      <text font="caption">
        {failed ? "Check" : authorized ? `${events.length} events` : "Connect"}
      </text>
    </vstack>,
  );
} else {
  // Lock Screen rectangle and all Home Screen sizes: a header, then one row for each event.
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
        {/* "Cached" marks events that come from an older saved answer. */}
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
      {/* The empty or error message, if there is one. */}
      {!!message && (
        <text font={authorized && !failed ? "headline" : "caption"} color={foreground}>
          {message}
        </text>
      )}
      {/* Without access, a link that opens the calendar access settings of ScriptWidget. */}
      {(!authorized || failed) && !accessory && (
        <link url="scriptwidget://calendar-access">
          <hstack spacing="6">
            <icon systemName="lock.open" size="14" />
            <text font="caption">{small ? "Settings" : "Open ScriptWidget"}</text>
          </hstack>
        </link>
      )}
      {/* A spacer at the end pushes the content to the top. */}
      {!accessory && <spacer />}
    </vstack>,
  );
}
