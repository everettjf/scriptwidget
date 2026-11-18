// A local flag, not a system Focus/home/device setting. No network or credentials.
const stateKey = "switch.enabled",
  size = $getenv("widget-size");
function readFlag() {
  const raw = $storage.getString(stateKey);
  if (!["", "true", "false"].includes(raw)) throw new Error("The saved local switch is invalid.");
  return raw === "true";
}
function writeFlag(desired) {
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
const enabled = readFlag(),
  dark = $device.isdarkmode(),
  background = dark ? "#111827" : "#eff6ff",
  ink = dark ? "#f8fafc" : "#1e3a8a",
  muted = dark ? "#cbd5e1" : "#475569";
if (size === "function" || size === "action") {
  // App Intents call the same declared handler after source evaluation.
} else if (size === "accessoryInline") {
  $render(<text>{enabled ? "Local switch on" : "Local switch off"}</text>);
} else if (size === "accessoryCircular") {
  $render(
    <vstack spacing="1">
      <icon systemName={enabled ? "checkmark.circle.fill" : "circle"} size="22" />
      <text font="caption2">{enabled ? "On" : "Off"}</text>
    </vstack>,
  );
} else if (size === "accessoryRectangular") {
  $render(
    <toggle actionID="setFlag" stateKey={stateKey} on={enabled}>
      <text font="caption">Local switch</text>
    </toggle>,
  );
} else {
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
