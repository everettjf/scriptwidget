# Your first ScriptWidget

This tutorial creates a widget in ScriptWidget Studio on Mac and makes it available on iPhone, iPad, and Mac through the existing ScriptWidget sync model.

On Android use the in-app editor, and on Windows or Linux the management window: open a template under Templates and choose "Use this template". See [ScriptWidget for Android](android/README.md), [Windows](windows/README.md#using-it) and [Linux](linux/README.md#using-it).

## 1. Create

Open ScriptWidget Studio and choose **Blank Widget**. Give it a short unique name. Every widget is a package whose entry point is `main.jsx`.

Replace the editor contents with:

```jsx
const family = $getenv("widget-size");

$render(
  <vstack frame="max" padding="16" background="#172554">
    <text font="caption" color="#93c5fd">MY FIRST WIDGET</text>
    <text font="title" color="#ffffff">Hello!</text>
    <text font="caption" color="#bfdbfe">Family: {family}</text>
  </vstack>
);
```

## 2. Preview and debug

Choose **All Sizes** to compare Small, Medium, and Large. Press **Command-R** to run and **Command-S** to save and refresh.

If rendering fails, open **Problems** for the runtime diagnostic and **Console** for script output. You can select the Runtime Debugger Skill in **Copilot**, then choose **Fix Runtime Error**. Review the proposed code before applying it.

## 3. Make it useful

- Use `fetch()` for public HTTP data and always render a fallback state.
- Use `$storage` for small persisted values and `$file` for package files.
- Use `$device`, `$location`, or `$health` only when the data is needed and authorized.
- Use `$getenv("widget-size")` to tailor information density per family.

See the [Runtime API](runtime-api.md) for the supported contract and resource limits.

## 4. Install

Save the script, add a ScriptWidget widget from the system widget gallery, and select the script in widget configuration. With the configured iCloud container and app group, the same package is available across your signed-in devices.

## 5. Next steps

- Start from a bundled template for a proven layout.
- Use **Generate with AI** for a complete first draft and **Copilot** for focused changes.
- Combine Skills such as Responsive Layout and Accessible Design.
- Share a package using the existing `.swt` import/export flow.

Never place API secrets directly in a widget you plan to share. Treat imported packages, network responses, and generated code as untrusted until reviewed.

## Habit Heatmap: daily check-ins

Create a widget from **Habit Heatmap** under New Widget. It starts with an empty
history, rather than sample activity. Small and medium widgets track Read;
large and extra-large widgets show Read, Run and Meditate. Tap **Check in** on a
Home Screen widget to save today's completion (iOS 17+ / macOS 14+). A successful
action requests a WidgetKit timeline reload; the system controls when it appears.
Lock Screen accessories display the first habit's streak without a check-in button.
The editor preview displays the saved state; previewing never creates a check-in.

Each habit can be completed once per local calendar day. Repeat taps are harmless.
An unfinished today preserves a streak ending yesterday; a missed yesterday resets
it. Heatmap columns start on Monday, checked days are colored, and future days are
blank. Calendar dates follow the device's local timezone when checking in; past
date labels do not shift when you travel. Regular WidgetKit refreshes update the
calendar after midnight; they are not guaranteed to run exactly at midnight.

History is saved offline in package-namespaced `$storage`, with up to 3,660 days
retained on the next check-in. It survives widget refreshes and app restarts, and
is separate for each package and habit. It is local storage, not iCloud history
sync. Copying or renaming a package creates a different storage namespace. Edit
habit display names and colors in `main.jsx`, keeping the `id` and action function
names unchanged to preserve history and button routing. Invalid saved data or a
failed write reports an error instead of claiming the check-in succeeded.

Template creation preserves the full package, including its permissions, minimum runtime, actions, nested source and resources. Every created copy gets a fresh package identifier. Templates with an invalid manifest or unsafe resources are rejected before a library entry appears.
