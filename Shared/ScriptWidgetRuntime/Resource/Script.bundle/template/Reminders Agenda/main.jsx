// Reminders Agenda — actual EventKit data on iPhone, iPad and Mac.
// Declare reminders, remindersWrite and storage. Grant access and select lists in Settings.
// Optional widget parameter: comma-separated list IDs from $reminders.lists().
// Browser previews use editable samples; native templates never seed fake reminders.
//
// $reminders runs on iPhone and iPad, and on Mac. It does not run on Android, Windows
// or Linux.
// This template shows how to read system data that needs permission, how to show a
// helpful message for every way that can fail, and how a button changes data safely.
// Try changing `limit` or the colors.

// The size being drawn. The Lock Screen sizes (iPhone and iPad only) start with "accessory".
const size = $getenv("widget-size");
const accessory = size.startsWith("accessory");
// Lock Screen widgets use the system's own colors ("primary", "secondary").
const dark = $device.isdarkmode();
const foreground = accessory ? "primary" : dark ? "#f3f4f6" : "#172033";
const secondary = accessory ? "secondary" : dark ? "#9ca3af" : "#68758b";
const background = accessory ? "clear" : dark ? "#131b2a" : "#f4f7fc";
const accent = accessory ? "primary" : "#5274d9";
const small = size === "small" || size === "systemSmall";
// How many reminders to ask for: 2 in small and Lock Screen sizes, 3 in medium, else 6.
const limit = accessory || small ? 2 : size === "medium" || size === "systemMedium" ? 3 : 6;
// What the query found. `message` is shown instead of the list, or below it.
let items = [],
  message = "",
  authorized = false,
  stale = false,
  failed = false;
// A "complete" request that was started and not yet confirmed; {} when there is none.
// $storage holds values saved for this package ("storage" permission in widget.json).
const pendingWrite = $storage.getJSON("pending-reminder-write");

// Read the reminders, unless a button action is running: widget-size is then "action" or
// "function", and the action reads what it needs itself.
if (size !== "action" && size !== "function") {
  try {
    // Check in order: does this system have Reminders, and has the user granted access?
    if (!$reminders.isAvailable()) message = "Reminders is unavailable on this device.";
    else if ($reminders.authorizationStatus() !== "authorized")
      message = small
        ? "Settings → Reminders in ScriptWidget."
        : "Connect Reminders in ScriptWidget Settings.";
    else {
      authorized = true;
      // The widget parameter (the parameter text set for this widget) may name the lists to
      // read. maxAgeSeconds: a saved result up to 60 seconds old may be reused.
      const parameter = $getenv("widget-param").trim();
      const options = { limit, maxAgeSeconds: 60 };
      if (parameter)
        options.listIDs = parameter
          .split(",")
          .map((id) => id.trim())
          .filter(Boolean);
      // Needs the "reminders" permission in widget.json. Without start and end, items()
      // returns the reminders due today, from local midnight to the next.
      const result = await $reminders.items(options);
      items = Array.isArray(result.items) ? result.items : [];
      // stale is true when the result is a saved one that is older than 60 seconds.
      stale = result.stale;
      if (!items.length) message = "No reminders due today.";
    }
  } catch (error) {
    // The error text contains a code. Turn the known ones into a hint, shorter in small sizes.
    failed = true;
    message = String(error).includes("No Reminder lists")
      ? small || accessory
        ? "Choose reminder lists in Settings."
        : "Choose reminder lists in ScriptWidget Settings."
      : String(error).includes("invalid_options")
        ? small || accessory
          ? "Review Reminders selection."
          : "Review your Reminders selection and widget parameter."
        : small || accessory
          ? "Open ScriptWidget to check access."
          : "Reminders could not load. Open ScriptWidget to check access.";
  }
}

// A random id in UUID format that names one write request.
function newRequestID() {
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (key) => {
    const value = Math.floor(Math.random() * 16);
    return (key === "x" ? value : (value & 3) | 8).toString(16);
  });
}
// The "complete-next" action from widget.json. The request is saved before it is sent
// and removed after it succeeded. If the outcome is unknown, the next tap sends the
// same request again, which cannot complete a second reminder.
async function completeNext() {
  let request = $storage.getJSON("pending-reminder-write");
  if (!request.requestID) {
    // maxAgeSeconds: 0 asks for fresh data, never a saved result.
    const options = { limit: 1, maxAgeSeconds: 0 };
    const parameter = $getenv("widget-param").trim();
    if (parameter)
      options.listIDs = parameter
        .split(",")
        .map((id) => id.trim())
        .filter(Boolean);
    const result = await $reminders.items(options);
    if (!result.items.length) {
      $render(<text>Nothing due today</text>);
      return;
    }
    const item = result.items[0];
    request = { requestID: newRequestID(), listID: item.listID, id: item.id, completed: true };
    if (!$storage.setJSON("pending-reminder-write", request))
      throw new Error("Could not save the reminder request. Nothing was changed.");
  }
  // Needs the "remindersWrite" permission in widget.json. Always await a write.
  await $reminders.setCompleted(request);
  $storage.remove("pending-reminder-write");
  $render(<text>Reminder completed</text>);
}

// Use only after inspecting the actual Reminders app for an uncertain result.
function clearPending() {
  $storage.remove("pending-reminder-write");
  $render(<text>Pending request cleared. Check Reminders before starting another action.</text>);
}

// The time of a reminder in the device's format, or "Today" for one without a time.
function reminderTime(item) {
  if (!item.hasTime) return "Today";
  return new Date(item.due).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

// Choose a layout.
if (size === "action" || size === "function") {
  $render(<text>Reminder action</text>);
} else if (small && (!authorized || failed)) {
  // Small and not connected: the whole widget is a link into the ScriptWidget app.
  $render(
    <link url="scriptwidget://reminders-access">
      <vstack frame="max" padding="14" spacing="6" alignment="leading" background={background}>
        <text font="headline" color={foreground}>
          Reminders
        </text>
        <text font="caption" color={secondary}>
          {failed ? "Review list access in Settings." : "Connect in ScriptWidget Settings."}
        </text>
        <spacer />
        <text font="caption" color={accent}>
          Open Settings →
        </text>
      </vstack>
    </link>,
  );
} else if (size === "accessoryInline") {
  // Lock Screen sizes (iPhone and iPad only).
  $render(
    <text>
      {items.length
        ? `${reminderTime(items[0])} ${items[0].title}`
        : failed
          ? "Check Reminders access"
          : authorized
            ? "Nothing due today"
            : "Connect Reminders"}
    </text>,
  );
} else if (size === "accessoryCircular") {
  $render(
    <vstack spacing="2">
      <icon systemName="checklist" size="20" />
      <text font="caption">
        {failed ? "Check" : authorized ? `${items.length} items` : "Connect"}
      </text>
    </vstack>,
  );
} else {
  // Every other size: a header, the reminders, a message, and buttons where there is room.
  // frame="max" fills the widget; padding is the space around the content, in points.
  $render(
    <vstack
      frame="max"
      padding={accessory ? "4" : "16"}
      spacing={accessory ? "4" : "10"}
      alignment="leading"
      background={background}
    >
      <hstack spacing="6">
        <icon systemName="checklist" size="16" color={accent} />
        <text font="caption" color={secondary}>
          {small ? "AGENDA" : "DUE TODAY"}
        </text>
        <spacer />
        {stale && (
          <text font="caption2" color={secondary}>
            Cached
          </text>
        )}
      </hstack>
      {items.map((item) => (
        <hstack spacing="10">
          <rect frame="3,30" color={accent} />
          <vstack alignment="leading" spacing="3">
            <text font={small || accessory ? "caption" : "headline"} color={foreground}>
              {item.title || "Untitled reminder"}
            </text>
            <text font="caption2" color={secondary}>
              {reminderTime(item)}
            </text>
          </vstack>
          <spacer />
        </hstack>
      ))}
      {/* The message: "No reminders due today.", or what to do about a problem. */}
      {!!message && (
        <text font={authorized && !failed ? "headline" : "caption"} color={foreground}>
          {message}
        </text>
      )}
      {(!authorized || failed) && !accessory && (
        <link url="scriptwidget://reminders-access">
          <hstack spacing="6">
            <icon systemName="lock.open" size="14" />
            <text font="caption">{small ? "Settings" : "Open ScriptWidget"}</text>
          </hstack>
        </link>
      )}
      {/* The buttons run the actions with these ids from widget.json. */}
      {!accessory && !small && pendingWrite.requestID && (
        <button actionID="clear-pending">
          <text font="caption">Checked Reminders? Clear pending</text>
        </button>
      )}
      {!accessory && !small && authorized && !failed && items.length > 0 && (
        <button actionID="complete-next">
          <text font="caption">Complete next</text>
        </button>
      )}
      {!accessory && <spacer />}
    </vstack>,
  );
}
