# ScriptWidget Package 2.0

A ScriptWidget project is a directory whose authoritative metadata lives in `widget.json`. Exported projects use the `.swt` extension, but the file is a ZIP archive so it can be inspected with standard tools.

## Minimal project

```text
My Widget/
├── widget.json
└── main.jsx
```

```json
{
  "entry": "main.jsx",
  "formatVersion": 2,
  "id": "com.example.my-widget",
  "name": "My Widget",
  "networkDomains": [],
  "permissions": [],
  "plugins": [],
  "runtimeVersion": "1.0",
  "supportedFamilies": ["systemSmall", "systemMedium", "systemLarge"],
  "version": "1.0.0"
}
```

The machine-readable contract is [`widget.schema.json`](../Shared/ScriptWidgetRuntime/Resource/widget.schema.json). Unknown fields are rejected by the schema so typos do not silently change a package's security declaration.

## Fields

- `formatVersion`: package contract version; currently exactly `2`.
- `id`: stable reverse-DNS-style identifier, 3–128 characters.
- `name`: human-readable project name, 1–80 characters.
- `version`: semantic version such as `1.2.0` or `1.2.0-beta.1`.
- `runtimeVersion`: required ScriptWidget runtime API; currently exactly `1.0`.
- `entry`: a relative `.js` or `.jsx` file inside the package.
- `supportedFamilies`: one or more WidgetKit families.
  iOS, iPadOS, and macOS 27 add `systemExtraLargePortrait`; packages may
  include it while retaining other families as fallbacks on older systems.
- `controls`: up to eight declarative Control Center buttons or toggles. Each
  control declares a stable `id`, an SF Symbol `systemImage`, and a JavaScript
  `action` function. Toggles also require `stateKey` and the `storage`
  permission; the new value is available to the action as
  `$getenv("control-value")`.
- `pushUpdates`: optional self-hosted WidgetKit push registration. The object
  contains an HTTPS `registrationURL` on a declared `networkDomains` host and a
  non-secret `channel`. ScriptWidget posts the WidgetKit token, package ID, and
  channel when the token changes; packages never receive the token in JSX.
- `permissions`: declared capabilities: `network`, `location`, `health`, `storage`, or `files`.
- `networkDomains`: lowercase host allowlist. It requires `network`; use exact hosts or a leading wildcard such as `*.example.com`.
- `plugins`: optional Data Source Plugin identifiers. Every data-source request also requires `network` and a matching `networkDomains` entry.
- Optional discovery fields: `description`, `category`, `tags`, `icon`, `preview`, `author`, and `license`.

The Mac Studio Config panel edits and validates these values before saving. New widgets get a manifest automatically. A legacy package containing `main.jsx` and optional `meta.json` is migrated when it is imported or exported.

## Import security

ScriptWidget treats every imported `.swt` as untrusted. Before extraction it checks the ZIP central directory and rejects:

- absolute paths, `..` traversal, backslashes, drive-style paths, invalid UTF-8, and excessive nesting;
- symbolic links, encrypted entries, multi-disk archives, malformed ZIP64 metadata, and unsupported compression methods;
- archives over 32 MiB, more than 500 entries, a file over 25 MiB, or more than 64 MiB expanded;
- malformed central directories and suspicious zero-byte compression claims.

Extraction uses a unique temporary directory that is removed after every attempt. The extracted tree is checked again before copying. The archive filename does not control the installed project directory; the validated manifest name does.

Permission declarations are surfaced for review during import and enforced by the Package 2.0 runtime. Network calls require `network`, use HTTPS, and must match `networkDomains`. Legacy packages remain compatible but do not gain access to the new plugin API.

## Compatibility

`meta.json` remains readable for bundled and existing projects. Package 2.0 makes `widget.json` authoritative when both exist. A package requiring an unknown format or runtime is rejected instead of being opened with undefined behavior.
