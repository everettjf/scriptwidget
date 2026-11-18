// A local flag, not a system Focus/home/device setting. No network or credentials.
// A switch whose state is saved with $storage, so the widget, the control and Shortcuts
// all show and change the same value. Try changing the texts and the icon.
// widget.json declares the "storage" permission (a toggle with a stateKey requires it),
// the three actions (setFlag, enableFlag, disableFlag) and the control. The functions
// below carry the names listed there.
// Control Widgets are on iPhone and iPad; Android shows a Quick Settings tile.
//
// The $storage key that holds the state, and the size being drawn.
const stateKey = "switch.enabled",
  size = $getenv("widget-size");
// Read the saved state. $storage.getString returns "" for a key that was never set,
// which counts as off.
function readFlag() {
  const raw = $storage.getString(stateKey);
  if (!["", "true", "false"].includes(raw)) throw new Error("The saved local switch is invalid.");
  return raw === "true";
}
// Save a new state. `desired` is true, false, or undefined to flip the current state.
function writeFlag(desired) {
  // compareAndSetString saves only if the value is still the one just read. If something
  // else changed it in between, read again and retry, at most 8 times.
  for (let attempt = 0; attempt < 8; attempt++) {
    const raw = $storage.getString(stateKey);
    if (!["", "true", "false"].includes(raw)) throw new Error("The saved local switch is invalid.");
    const next = desired === undefined ? raw !== "true" : desired;
    if ($storage.compareAndSetString(stateKey, raw, String(next))) {
      $render(<text>{next ? "Local switch on" : "Local switch off"}</text>);
      return;
    }
  }
  throw new Error("The local switch changed. Refresh and try again.");
}
// The actions named in widget.json. A toggle passes the wanted state in
// $getenv("action-value") as "true" or "false"; without a value the switch is flipped.
function setFlag() {
  const value = $getenv("action-value");
  if (value !== "" && value !== "true" && value !== "false")
    throw new Error("Invalid switch value.");
  writeFlag(value === "" ? undefined : value === "true");
}
function enableFlag() {
  writeFlag(true);
}
function disableFlag() {
  writeFlag(false);
}
// Read the data, and choose colors for dark or light mode.
const enabled = readFlag(),
  dark = $device.isdarkmode(),
  background = dark ? "#111827" : "#eff6ff",
  ink = dark ? "#f8fafc" : "#1e3a8a",
  muted = dark ? "#cbd5e1" : "#475569";
// Choose what to draw. While an action runs, the size is "function" or "action".
if (size === "function" || size === "action") {
  // App Intents call the same declared handler after source evaluation.
} else if (size === "accessoryInline") {
  // Lock Screen line: text only.
  $render(<text>{enabled ? "Local switch on" : "Local switch off"}</text>);
} else if (size === "accessoryCircular") {
  // Lock Screen circle: an icon with On or Off.
  $render(
    <vstack spacing="1">
      <icon systemName={enabled ? "checkmark.circle.fill" : "circle"} size="22" />
      <text font="caption2">{enabled ? "On" : "Off"}</text>
    </vstack>,
  );
} else if (size === "accessoryRectangular") {
  // Lock Screen rectangle: a working toggle. actionID names the action in widget.json to
  // run on a tap, and stateKey is the $storage key that holds the state.
  $render(
    <toggle actionID="setFlag" stateKey={stateKey} on={enabled}>
      <text font="caption">Local switch</text>
    </toggle>,
  );
} else {
  // Home Screen sizes: a title, the toggle and a note.
  $render(
    <vstack frame="max" alignment="leading" padding="14" spacing="10" background={background}>
      <hstack>
        <icon systemName="switch.2" size="22" color="#2563eb" />
        <text font="headline" color={ink}>
          Local switch
        </text>
      </hstack>
      <spacer />
      <toggle actionID="setFlag" stateKey={stateKey} on={enabled}>
        <text color={ink}>{enabled ? "On" : "Off"}</text>
      </toggle>
      <spacer />
      <text font="caption2" color={muted}>
        Shared with this widget’s control and Shortcuts
      </text>
    </vstack>,
  );
}
