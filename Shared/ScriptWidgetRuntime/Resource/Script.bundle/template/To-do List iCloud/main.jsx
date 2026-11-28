// A three-task example. Edit the labels in this source to make your own list.
// The document saves which tasks exist and whether they are done. Stable IDs let
// two devices update different tasks without overwriting one another.
const documentName = "todo.json";
const tasks = [
  { id: "outline", title: "Write an outline", finish: "finishOutline", reopen: "reopenOutline" },
  { id: "review", title: "Review the draft", finish: "finishReview", reopen: "reopenReview" },
  { id: "publish", title: "Share the draft", finish: "finishPublish", reopen: "reopenPublish" },
];
const empty = { version: 1, items: {} };
const open = { change: 0, done: false };

// Existing example tasks start open. The third stays hidden until its Add button is tapped.
function taskState(data, id) {
  return data.items[id] ?? (id === "publish" ? null : open);
}

function validate(value) {
  if (
    !value ||
    Object.keys(value).sort().join(",") !== "items,version" ||
    value.version !== 1 ||
    !value.items ||
    typeof value.items !== "object" ||
    Array.isArray(value.items)
  )
    throw new Error("Unrecognized to-do document.");

  for (const [id, state] of Object.entries(value.items)) {
    if (
      !tasks.some((task) => task.id === id) ||
      !state ||
      Object.keys(state).sort().join(",") !== "change,done" ||
      !Number.isSafeInteger(state.change) ||
      state.change < 1 ||
      typeof state.done !== "boolean"
    )
      throw new Error("Unrecognized saved task.");
  }
  return value;
}

// Each task has a logical change count. The larger count wins for that task.
// If two offline edits have the same count, completion wins the tie.
function mergeHeads(heads) {
  const items = {};
  for (const head of heads) {
    for (const [id, state] of Object.entries(validate(head.value).items)) {
      const earlier = items[id];
      if (
        !earlier ||
        state.change > earlier.change ||
        (state.change === earlier.change && state.done)
      )
        items[id] = state;
    }
  }
  return { version: 1, items };
}

const stale = (error) => String(error).includes("[icloud:staleRevision]");

// A render reads only. A declared action can commit a new revision. An explicit
// result (done or open) keeps retries from turning one tap into a second toggle.
async function saveTask(id, done, add = false) {
  for (let attempt = 0; attempt < 3; attempt++) {
    const snapshot = await $icloud.readJSON(documentName);
    if (snapshot.state === "conflict") throw new Error("Tap Sync to merge the list first.");
    const data =
      snapshot.value === null && snapshot.revision === "" ? empty : validate(snapshot.value);
    const prior = taskState(data, id);
    if (add ? prior !== null : prior === null || prior.done === done) return;
    const change = (prior?.change ?? 0) + 1;
    if (!Number.isSafeInteger(change)) throw new Error("This task has reached its change limit.");
    const next = { version: 1, items: { ...data.items, [id]: { change, done } } };
    try {
      await $icloud.writeJSON(documentName, next, snapshot.revision);
      return;
    } catch (error) {
      if (!stale(error)) throw error;
    }
  }
  throw new Error("The list changed while saving. Try again.");
}

async function changeTask(id, done, add) {
  await saveTask(id, done, add);
  $render(<text>To-do list saved on this device</text>);
}

async function addPublish() {
  await changeTask("publish", false, true);
}
async function finishOutline() {
  await changeTask("outline", true);
}
async function reopenOutline() {
  await changeTask("outline", false);
}
async function finishReview() {
  await changeTask("review", true);
}
async function reopenReview() {
  await changeTask("review", false);
}
async function finishPublish() {
  await changeTask("publish", true);
}
async function reopenPublish() {
  await changeTask("publish", false);
}

async function syncTasks() {
  await $icloud.sync();
  for (let attempt = 0; attempt < 3; attempt++) {
    const snapshot = await $icloud.readJSON(documentName);
    if (snapshot.state !== "conflict") {
      $render(<text>iCloud exchange requested</text>);
      return;
    }
    const merged = mergeHeads(snapshot.conflicts);
    try {
      await $icloud.resolveJSON(documentName, merged, snapshot.revision);
      $render(<text>Conflicting lists merged on this device</text>);
      return;
    } catch (error) {
      if (!stale(error)) throw error;
    }
  }
  throw new Error("The list changed while merging. Try Sync again.");
}

const size = $getenv("widget-size");
if (size !== "function" && size !== "action") {
  const dark = $device.isdarkmode();
  const background = dark ? "#19312E" : "#EAF5EF";
  const ink = dark ? "#ECFCF4" : "#123A2B";
  const accent = dark ? "#90E4BF" : "#17654A";
  try {
    const snapshot = await $icloud.readJSON(documentName);
    const conflict = snapshot.state === "conflict";
    const data = conflict
      ? mergeHeads(snapshot.conflicts)
      : snapshot.value === null && snapshot.revision === ""
        ? empty
        : validate(snapshot.value);
    const visible = tasks.filter((task) => taskState(data, task.id));
    const done = visible.filter((task) => taskState(data, task.id).done).length;
    $render(
      <vstack frame="max" alignment="leading" padding="12" spacing="4" background={background}>
        <hstack>
          <text font="headline" color={ink}>
            To-do · iCloud
          </text>
          <spacer />
          <text font="caption" color={accent}>{`${done}/${visible.length}`}</text>
        </hstack>
        {visible.map((task) => {
          const state = taskState(data, task.id);
          const row = (
            <hstack spacing="6">
              <icon
                systemName={state.done ? "checkmark.square.fill" : "square"}
                size="13"
                color={accent}
              />
              <text font="caption" color={ink}>
                {task.title}
              </text>
            </hstack>
          );
          return conflict ? (
            row
          ) : (
            <button actionID={state.done ? task.reopen : task.finish}>{row}</button>
          );
        })}
        <spacer />
        <hstack spacing="8">
          {!conflict && !data.items.publish && (
            <button actionID="addPublish">
              <text font="caption" color={accent}>
                Add task
              </text>
            </button>
          )}
          <button actionID="syncTasks">
            <text font="caption" color={accent}>
              {conflict ? "Sync to merge" : "Sync"}
            </text>
          </button>
        </hstack>
        <text font="caption2" color={accent}>
          {conflict ? "Offline edits found" : "iCloud may be delayed"}
        </text>
      </vstack>,
    );
  } catch (error) {
    const needsConnection = /notConnected|accountChanged/.test(String(error));
    const unsupported = String(error).includes("unsupported_platform");
    $render(
      <vstack frame="max" padding="14" spacing="6" background={background}>
        <text font="headline" color={ink}>
          To-do · iCloud
        </text>
        <text font="caption" color={accent}>
          {unsupported
            ? "Use Daily Focus Checklist on this platform."
            : needsConnection
              ? "Open iCloud Data in ScriptWidget to connect."
              : "Couldn’t read the list. Review iCloud Data in ScriptWidget."}
        </text>
        {!unsupported && !needsConnection && (
          <button actionID="syncTasks">
            <text font="caption" color={accent}>
              Retry sync
            </text>
          </button>
        )}
      </vstack>,
    );
  }
}
