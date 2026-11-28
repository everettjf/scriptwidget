# Build an interactive to-do widget

Open **Gallery** in [Web Studio](https://asp.run/scriptwidget/studio/) or **Templates** in ScriptWidget. Search for **Daily Focus Checklist** to try local storage, then **To-do List iCloud** to try the same kind of interaction with a shared cloud document.

## Start on one device

Create a copy of **Daily Focus Checklist**. Set the widget parameter to a comma-separated list, such as `Read,Walk,Plan tomorrow`, or edit the default labels in its source. Choose the large widget to show up to eight tasks. Tap a task to check it off or reopen it. Each day starts with an unchecked list.

The package declares `storage` in [widget.json](../Daily%20Focus%20Checklist/widget.json). The button's `actionID` selects a function declared in that manifest. The function reads today's saved labels, edits the record, and calls `$storage.compareAndSetString` so that another tap cannot silently overwrite a newer save. See the [local source](../Daily%20Focus%20Checklist/main.jsx) and [storage API](../../../../../../docs/storage-api.md).

## Try iCloud on iPhone, iPad or Mac

1. Create a copy of **To-do List iCloud** and open its **iCloud Data** menu in ScriptWidget. Create a store and confirm access.
2. Add the installed package to the system widget gallery. Two sample tasks are ready to use. Tap **Add task** to add the third. Tap a task again to reopen it.
3. On a second device signed into the same Apple Account, install the same template and connect it to the same store ID. Tap **Sync** to request an exchange. iCloud and WidgetKit choose when updates arrive.

On Android, the same API uses a folder you pick. That folder cannot exchange data with the Apple iCloud store. Windows and Linux can use the local checklist.

This cloud example keeps three stable task IDs. Edit the labels in [main.jsx](main.jsx) and use the same labels on both devices. The document records task presence and completion, while the labels ship in the source. Local checklist history stays in its local package. The cloud example uses a separate store and has no task deletion or reset.

On Apple devices, the revisions appear under `iCloud Drive → ScriptWidget → WidgetData → <store ID> → todo.json`. The app manages the revision files in that directory.

## Trace a button tap

```jsx
<button actionID="finishOutline">
  <text>Write an outline</text>
</button>
```

[widget.json](widget.json) declares the `icloud` permission and maps `finishOutline` to the corresponding function in [main.jsx](main.jsx). Rendering calls `$icloud.readJSON("todo.json")` and updates the row icons. A tap reads the latest revision, saves the requested state with `$icloud.writeJSON`, and retries if the revision changed. Explicit finish and reopen actions prevent a retry from toggling a task twice.

If two devices edit offline, both revisions can arrive as a conflict. **Sync** merges each task independently. The higher change count wins, and completion wins an equal-count tie. The action calls `resolveJSON` with the observed revision token. Each saved tap or merge uses one revision. The store has a 256-revision limit, so use a separate store for this tutorial. See the [iCloud JSON API](../../../../../../docs/icloud-json-api.md) for quotas and signed-device verification.

## Preview without an iCloud account

In Web Studio, create a copy and open **Mock Data**. In **Action to simulate**, choose **Add sample task** and click **Run simulated action**. The preview uses a connected mock store with no documents by default. To see a saved list, select **iCloud JSON** in **Data source**, paste this fixture and click **Apply mock data**:

```json
{
  "connected": true,
  "available": true,
  "documents": {
    "todo.json": {
      "value": {"version": 1, "items": {"outline": {"change": 1, "done": true}}},
      "revision": "demo-1",
      "state": "cached",
      "conflicts": []
    }
  }
}
```

Web preview actions use a fresh iCloud mock on each run. Update the fixture to see a different saved state. Real sync requires the installed native app and an explicit connection on each device.
