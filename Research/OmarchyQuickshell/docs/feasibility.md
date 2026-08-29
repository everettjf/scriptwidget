# ScriptWidget on Omarchy 4: feasibility study

## Decision

An Omarchy 4 host is feasible, but it should be a new Linux runtime rather than
a port of the current Swift sources. The recommended shape is:

```text
Package 2.0 (widget.json + JS/JSX + resources)
                 |
      scriptwidget-linux-runner
  validation / JSX compile / JS sandbox / APIs
                 |
       bounded JSON element tree
                 |
    Omarchy Quickshell service plugin
  screen placement / theme / QML rendering
```

The package contract can remain largely shared. Execution and rendering cannot:
the current runtime is coupled to Apple's JavaScriptCore Objective-C bridge and
the element renderer is a native SwiftUI switch.

## What OmaClock proves

The inspected upstream snapshot is commit
`e63ef6e7a34c87730ad56a836ed5bf95ec52ea7f`.

Its `manifest.json` declares two plugin kinds:

- `service`: `DesktopClock.qml`, kept loaded for the whole shell session.
- `bar-widget`: `Control.qml`, a control surface that retrieves the service via
  `root.bar.shell.serviceFor(root.moduleName)`.

`DesktopClock.qml` supplies the desktop integration pattern we need:

1. `Variants { model: Quickshell.screens }` creates one surface per monitor.
2. A fullscreen transparent `PanelWindow` is anchored on every edge.
3. `WlrLayershell.layer: WlrLayer.Bottom` puts it behind normal application
   windows but above the wallpaper.
4. `exclusionMode: ExclusionMode.Ignore` avoids reserving tiling space.
5. `WlrKeyboardFocus.None` avoids stealing keyboard focus.
6. `mask: Region {}` makes the surface click-through. This is required even
   with no `MouseArea` on affected Quickshell 0.3.x builds.
7. Omarchy theme roles are consumed directly through `qs.Commons` `Color.*`.

The project stores settings at `~/.config/omaclock/config.json`. It reads the
file with a `Process` running `cat` every two seconds and writes via a shell
heredoc. This works for a small plugin, but is not an acceptable persistence or
security boundary for untrusted ScriptWidget packages: the runner must own
canonical path checks, atomic writes, quotas, and package namespaces.

## Compatibility with the existing runtime

### Reusable without semantic changes

- Package 2.0 directory shape and most `widget.json` validation.
- `runtimeVersion`, entry point, package ID, version, permissions and declared
  network domains.
- The JSX authoring model and the bounded element-tree concept.
- Non-Apple-neutral elements such as stacks, grids, text, shapes, spacers,
  dividers, progress, badges, chips and stats.
- Existing Babel preset/support bundle, subject to proving it runs under the
  selected Linux JavaScript engine and produces identical fixtures.

### Requires a Linux implementation

- JavaScript execution: current code imports Apple's `JavaScriptCore`, exposes
  Swift/Objective-C `JSExport` classes, and returns native element objects.
- Rendering: the authoritative element switch returns SwiftUI `AnyView`s.
- Network, file, storage and data-source APIs currently call Apple/Foundation
  implementations and obtain state through `JSContext.current()`.
- Images, symbols, fonts, dates, gauges and charts need QML equivalents and
  cross-platform conformance fixtures.
- WidgetKit timelines, App Intents, Live Activities, Control Widgets,
  HealthKit, location authorization and SF Symbols do not map directly.

## Recommended runtime boundary

Do not evaluate package JavaScript inside the long-lived `omarchy-shell` QML
process. Omarchy plugins themselves are unsandboxed; adding untrusted widget
code there would enlarge the blast radius to the whole user session.

Use a separate runner process with this contract:

```json
{
  "protocolVersion": 1,
  "request": {
    "packageRoot": "/canonical/path",
    "family": "systemMedium",
    "appearance": "dark",
    "locale": "en-US"
  }
}
```

The response should contain either a fully resolved, data-only element tree or
a structured error. Enforce the same depth, node, byte, time and network limits
before QML receives it. Never send functions or arbitrary QML through this
boundary.

Node.js is useful for an early compatibility prototype because Babel and JSX
are straightforward, but a production design must not rely on Node's default
unrestricted `fs`, `process`, module loading or networking. Options are:

- a small Rust/C++ runner embedding QuickJS, with only explicit host APIs;
- a hardened Node subprocess with generated policy and OS sandboxing;
- WebKitGTK JavaScriptCore through its C API, which shares an engine family but
  not Apple's Objective-C `JSExport` layer.

QuickJS is the cleanest security-oriented target; Node is the fastest proof of
concept. Engine choice must be settled through output-conformance and resource-
limit tests, not API resemblance.

## Rendering and placement

The QML host should own one bottom-layer surface per monitor and render a model
of instances rather than one fullscreen widget. Each instance needs stable
identity, monitor selection, normalized or pixel position, family, scale,
visibility and refresh policy.

Click-through and interaction conflict. A completely empty input region is safe
for wallpaper interaction but makes buttons/toggles unusable. Interactive mode
must construct an input region limited to widget rectangles, or present widgets
on a summoned dashboard workspace/overlay. The latter is the safer first
release and matches the original Reddit author's old-macOS-Dashboard behavior.

## Proposed delivery phases

### Phase 0 — surface smoke test

Install the prototype in this directory on Omarchy 4 and verify bottom-layer
placement, click-through, theming, scaling and multiple monitors. It uses no
ScriptWidget packages and proves only the compositor integration.

### Phase 1 — read-only vertical slice

- Validate one local Package 2.0 package.
- Execute deterministic JS/JSX in an external runner.
- Return a bounded tree.
- Render `vstack`, `hstack`, `zstack`, `text`, `spacer`, `rect`, `roundedrect`,
  `circle`, `divider` and `progress`.
- Support small/medium/large fixed families, dark/light appearance and manual
  refresh.
- No network, `$file`, `$storage`, actions or imported plugins.

### Phase 2 — safe data widgets

Add package-relative files, namespaced bounded storage, domain-allowlisted HTTPS
fetch with private-host rejection, response budgets, scheduled refresh, images
and error/last-known-good UI.

### Phase 3 — interaction and distribution

Add bounded input regions or a dashboard overlay, actions, a bar controller,
transactional package installation, signatures/hashes for gallery content and
an Omarchy plugin repository. Keep Apple-only capabilities explicitly
unsupported rather than silently changing their semantics.

## Main risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Untrusted JS in `omarchy-shell` | User-session compromise or shell crash | Separate sandboxed runner; data-only IPC |
| QML/SwiftUI semantic drift | Same package renders differently | Golden element-tree and screenshot fixtures |
| Transparent surface captures input | Wallpaper shortcuts stop working | Empty or precisely bounded input region |
| Multi-monitor/scale drift | Wrong size or placement | Per-screen instances and normalized coordinates |
| Network permission bypass | Local-network or credential exposure | Runner-owned allowlist, DNS/IP checks and budgets |
| Node dependency/escape | Arbitrary filesystem/process access | Prototype only; sandbox or replace engine |
| Omarchy/Quickshell API churn | Plugin breaks after updates | Pin minimum versions and CI against stable Omarchy |

## Feasibility verdict

- **Desktop surface:** high confidence, directly demonstrated by OmaClock.
- **Read-only JSX subset:** high confidence, moderate implementation effort.
- **Broad visual compatibility:** feasible but substantial; every native tag and
  property needs an explicit QML mapping and conformance tests.
- **Full parity:** not realistic because several APIs are Apple-only.
- **Safe public distribution:** feasible only with a separate constrained
  runner; directly evaluating widget code in QML is a no-go.

