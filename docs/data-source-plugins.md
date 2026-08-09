# Data Source Plugins

Data Source Plugin 1.0 lets a widget call a third-party HTTPS API through a small, reviewable manifest. A plugin is data, not executable native code: it cannot read files, access secrets, run shell commands, or expand a widget's permissions.

## Try the built-ins on Mac

Open **File → Data Source Lab** (`⇧⌘D`). ScriptWidget includes Open-Meteo and the GitHub Public API. Choose an operation, edit its parameters, run the request, inspect timing and output, then copy the generated widget code.

## Declare access in a widget

Package 2.0 requires all three declarations:

```json
{
  "permissions": ["network"],
  "networkDomains": ["api.open-meteo.com"],
  "plugins": ["app.scriptwidget.datasource.open-meteo"]
}
```

Call the operation from `main.jsx`:

```jsx
const weather = await $dataSource.request(
  "app.scriptwidget.datasource.open-meteo",
  "forecast",
  { latitude: "37.7749", longitude: "-122.4194" }
);
```

The runtime rejects undeclared plugins and hosts. Requests are HTTPS-only, share the widget network budget, and have a 2 MiB response limit.

## Create and distribute a plugin

A plugin directory contains `plugin.json` and an optional `README.md`. Use [`plugin.schema.json`](../Shared/ScriptWidgetRuntime/Resource/plugin.schema.json) for editor validation. Operations map parameters to a URL path, query, header, or JSON body and may return JSON or UTF-8 text.

Zip those files as a `.swplugin` archive and import it in Data Source Lab. Import fails closed on unknown manifest keys, unsafe archive paths, invalid identifiers, non-HTTPS URLs, undeclared hosts, or unsupported runtime versions.

Version 1 intentionally does not provide credential storage. This prevents an imported widget or plugin from silently acquiring API secrets; authenticated-source support should use an explicit user-owned credential capability in a later contract version.
