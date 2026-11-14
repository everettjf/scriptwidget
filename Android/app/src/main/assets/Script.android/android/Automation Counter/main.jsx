// A counter with two declared actions. The buttons run them, and so can
// another app: on Android turn on Settings > Automation, allow this package,
// and send the "increment" or "reset" action from Tasker or a similar app.
const valueKey = "counter.value", sourceKey = "counter.source";

function read() {
  const value = Number($storage.getString(valueKey));
  return Number.isFinite(value) ? value : 0;
}
function write(value) {
  $storage.setString(valueKey, String(value));
  // "widget" for a tap, "shortcut" for an app shortcut, "automation" for another app.
  $storage.setString(sourceKey, $getenv("action-source"));
  $render(<text>{"Count " + value}</text>);
}
function increment() { write(read() + 1); }
function reset() { write(0); }

const size = $getenv("widget-size");
if (size === "action" || size === "function") {
  // The host calls the declared function after this script was evaluated.
} else {
  const source = $storage.getString(sourceKey);
  // A small widget has room for the icons only.
  const small = size === "small";
  const control = (id, symbol, title) => (
    <button actionID={id}>{small ? <icon systemName={symbol} size="26" color="material.primary" /> : <label systemName={symbol} title={title} color="material.primary" />}</button>
  );
  $render(
    <vstack frame="max" spacing="6" padding="14" background="material.surfaceContainer">
      <text font="caption" color="material.onSurfaceVariant">Counter</text>
      <text font="largeTitle,bold" color="material.primary">{String(read())}</text>
      <text font="caption2" color="material.onSurfaceVariant">{source ? "Changed by " + source : "Not changed yet"}</text>
      <hstack spacing={small ? "28" : "16"}>
        {control("increment", "plus.circle.fill", "Add one")}
        {control("reset", "arrow.counterclockwise", "Reset")}
      </hstack>
    </vstack>
  );
}
