// A counter with two declared actions. The buttons run them, and so can
// another app: on Android turn on Settings > Automation, allow this package,
// and send the "increment" or "reset" action from Tasker or a similar app.
// The actions and their functions are declared under "actions" in widget.json, which
// also lists the "storage" permission that $storage needs.
// Try: change the step in increment(), or add a third action here and in widget.json.
// The keys under which $storage, the small store of this package, keeps the two values.
const valueKey = "counter.value",
  sourceKey = "counter.source";

// The count is stored as text. If the text is not a number, start again from 0.
function read() {
  const value = Number($storage.getString(valueKey));
  return Number.isFinite(value) ? value : 0;
}
// Save the new count and what caused the change.
function write(value) {
  $storage.setString(valueKey, String(value));
  // "widget" for a tap, "shortcut" for an app shortcut, "automation" for another app.
  $storage.setString(sourceKey, $getenv("action-source"));
  $render(<text>{"Count " + value}</text>);
}
// These two names are the "function" values of the actions in widget.json.
function increment() {
  write(read() + 1);
}
function reset() {
  write(0);
}

// For a widget this is "small", "medium" or "large". "action" and "function" mean the
// script was started to run an action, not to draw the widget.
const size = $getenv("widget-size");
if (size === "action" || size === "function") {
  // The host calls the declared function after this script was evaluated.
} else {
  // Empty text until the count was changed for the first time.
  const source = $storage.getString(sourceKey);
  // A small widget has room for the icons only.
  const small = size === "small";
  // One button. actionID names an action declared in widget.json.
  const control = (id, symbol, title) => (
    <button actionID={id}>
      {small ? (
        <icon systemName={symbol} size="26" color="material.primary" />
      ) : (
        <label systemName={symbol} title={title} color="material.primary" />
      )}
    </button>
  );
  // Draw the widget. frame="max" makes the stack fill it. Colors named material.<role>
  // follow the Android wallpaper.
  $render(
    <vstack frame="max" spacing="6" padding="14" background="material.surfaceContainer">
      <text font="caption" color="material.onSurfaceVariant">
        Counter
      </text>
      <text font="largeTitle,bold" color="material.primary">
        {String(read())}
      </text>
      <text font="caption2" color="material.onSurfaceVariant">
        {source ? "Changed by " + source : "Not changed yet"}
      </text>
      <hstack spacing={small ? "28" : "16"}>
        {control("increment", "plus.circle.fill", "Add one")}
        {control("reset", "arrow.counterclockwise", "Reset")}
      </hstack>
    </vstack>,
  );
}
