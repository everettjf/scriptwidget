# Your first ScriptWidget

This tutorial creates a widget in ScriptWidget Studio on Mac and makes it available on iPhone, iPad, and Mac through the existing ScriptWidget sync model.

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
