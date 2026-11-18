# ScriptWidget for Linux

Status: in development on branch `linux`. There is no release yet and nothing shows on a desktop yet. What exists is the runtime, the painter and the command line (phase 1 of [plan.md](plan.md), written in Chinese). What was tested and on which machine is in [testing.md](testing.md); what is left is in [TODO.md](TODO.md).

ScriptWidget for Linux will put the same Package 2.0 widgets that run on iPhone, iPad, Mac, Android and Windows on the Linux desktop, first on [Omarchy](https://omarchy.org). It is written in Rust and runs the same shared JavaScript as Android and Windows in the same QuickJS-NG sources.

## Parts

| Part | Crate | State |
| --- | --- | --- |
| Engine: QuickJS-NG behind a safe wrapper | `Linux/crates/sw-quickjs` | Done |
| Runtime: packages, archives, compiler, executor, `Intl`, native APIs, Data Source Plugins, timeline | `Linux/crates/sw-core` | Done |
| Painter: element tree to bitmap and tap regions, on Skia | `Linux/crates/sw-render` | Done; see the list of differences in [TODO.md](TODO.md) |
| Command line `scriptwidget` | `Linux/crates/sw-cli` | The commands that need no background service |
| Background service, Omarchy display plugin | planned `sw-host`, `Linux/omarchy-plugin` | Not started (phase 2). A throwaway check of the display is in `Linux/spikes/plugin` |
| Management window | planned `sw-studio` (GPUI) | Not started (phase 3). A throwaway check is in `Linux/spikes/gpui` |

## Building

Needs Rust 1.85 or later, a C compiler, `pkg-config`, the development files of ICU, fontconfig and FreeType, and Node 24 or later for the shared JavaScript.

```
cd Web/studio && npm ci                      # once, for esbuild
node Linux/scripts/build-shared-js.mjs        # shared JavaScript -> Linux/assets, parity corpus -> Linux/tests/assets
cd Linux
cargo test --locked --workspace
cargo build --locked --release -p sw-cli      # target/release/scriptwidget
sh scripts/asan-test.sh                       # engine binding tests with AddressSanitizer in QuickJS (Linux only)
```

Run `node Linux/scripts/build-shared-js.mjs` again after changing `Web/preview-engine/src`, the support bundle or `Android/core/src/main/js`. Those sources are shared with Android and Windows: a change there needs their suites as well.

`Linux/assets`, `Linux/tests/assets` and `Linux/target` are generated and not checked in.

### Where the program finds its files

The program reads the generated JavaScript and the bundled templates from a data directory, never from the repository:

```
<prefix>/bin/scriptwidget
<prefix>/share/scriptwidget/runtime/      kernel.js and the other generated files
<prefix>/share/scriptwidget/templates/    template/ component/ api/
```

`sh Linux/scripts/stage-resources.sh <prefix>/share/scriptwidget` assembles it. The first location that holds `runtime/kernel.js` wins: `SCRIPTWIDGET_RESOURCES` if set; `../share/scriptwidget` next to the executable; `scriptwidget` under each entry of `XDG_DATA_DIRS`. For development, `SCRIPTWIDGET_RUNTIME_ASSETS` and `SCRIPTWIDGET_TEMPLATES` override each half.

User data is in `$XDG_DATA_HOME/scriptwidget` (`Packages`, `Storage`, `Plugins`, `Staging`), by default `~/.local/share/scriptwidget`; caches are in `$XDG_CACHE_HOME/scriptwidget`. `SCRIPTWIDGET_DATA` or `--data` names another folder.

## The command line

Every command prints one JSON report on standard output; errors and warnings are repeated on standard error as `error: [code] message`. Color is used only on a terminal and never when `NO_COLOR` is set.

| Command | What it does |
| --- | --- |
| `scriptwidget new <name> [--template <group/name>] [--directory <folder>]` | Creates a package from a template, or from a starter |
| `scriptwidget check <dir> [--fail-on-warning]` | Validates the manifest and compiles; runs nothing |
| `scriptwidget run <dir> [--family F] [--param P] [--dark]` | Executes; reports the element tree, logs and errors |
| `scriptwidget render <dir> --output <png> [--family F] [--scale N] [--now <ms>]` | Executes and draws a PNG; reports size, tap regions and timings. Needs no graphical session |
| `scriptwidget timeline <dir> [--now <ms>]` | Reports the timeline |
| `scriptwidget pack <dir> [file.swt] [--force]` | Exports a `.swt` |
| `scriptwidget install <.swt or dir>`, `list`, `templates` | Installed packages and bundled templates |
| `scriptwidget doctor` | Checks the installation: files, engine, painter, fonts, data folder |
| `add`, `remove`, `widgets`, `refresh`, `dev`, `peek`, `arrange`, `watch`, `tap`, `move`, `screen`, `theme`, `menu` | Need the background service, which does not exist yet: exit code 69 |

Families: `small` 170×170, `medium` 329×170, `large` 329×345, `extraLarge` 639×345 points, multiplied by `--scale` (default 2).

| Exit code | Meaning |
| --- | --- |
| 0 | Passed |
| 1 | The package, archive or script is at fault |
| 2 | Usage or environment: missing folder, unwritable or unsafe output, missing runtime files |
| 3 | Internal error |
| 69 | Needs the background service |

Every report has `reportVersion` (1), `command`, `status` (`passed`, `failed`, `error`), `ok`, `tool`, `error` and `diagnostics`. Package commands add `backend` (`linux-native`), `package`, `sourceHash`, `manifest` and `checks` (`package`, `compile`, `execute`, `render`, `export`, each `passed`, `failed` or `notRun`).

Differences from the Mac and Windows command lines: reports are always JSON; `render --output` names one PNG file, as on Windows (the Mac writes a folder with a light and a dark picture); there is no `preview` command and there are no fixtures, the APIs are real; a script error still writes the picture of the error card and exits with 1.

## How it runs a widget

As on Android and Windows:

1. **Compile.** The package's JSX is compiled by the shared Babel bundle inside QuickJS. The manifest is checked by the shared validator.
2. **Execute.** The script runs in a fresh QuickJS context with a 64 MB memory limit, a stack limit and a 5-second deadline. It reaches the system only through host calls, which check the manifest's permissions and network domains first.
3. **Lay out.** The shared renderer runs in a second QuickJS context that only ever sees the element tree, never package code. Text is measured by the Skia paragraph code that later draws it.
4. **Draw.** The laid-out tree is painted with Skia on a CPU surface into a bitmap with per-pixel transparency.

Every bundled package that needs no live data produces the same element tree on Linux as on iPhone, byte for byte; the tests check this.

## Differences from the other platforms

`$system.platform()` returns `"linux"`. Anything not listed is meant to work as on Windows (see [the Windows page](../windows/README.md)).

| Area | On Linux |
| --- | --- |
| Rendering modes | Always `fullColor`; `backgroundMaterial` uses the opaque `background` fallback |
| Fonts | Inter and the six display fonts are built into the program. Chinese, Japanese, Korean and emoji use system fonts found through fontconfig; the order of the Chinese, Japanese and Korean faces follows the locale. Monospace and serif are the user's fontconfig choices |
| `animation` | The first frame, as on Android and Windows |
| `<gif>` | Every frame is decoded with its delay (at most 60 frames) for the display to cycle; one render shows the first frame |
| `$device`, `$system` | `model` is `"PC"`, `name` and `hostName` are the host name, `brightness` is `1`, `thermalState` is `"nominal"`; the battery is the first system battery under `/sys/class/power_supply`, and a machine without one reports level 1 and `"full"`; `systemVersion` is `VERSION_ID` from `os-release`, or the kernel release where there is none |
| `$storage`, `$file`, `fetch`, `$http`, `$xml`, `$dataSource`, `$weather` | Yes, with the same permissions, network-domain declarations, private-address refusal and budgets. `$weather` is the MET Norway forecast |
| `$calendar`, `$reminders`, `$health`, `$photos`, `$contacts`, `$documents`, `$home`, `$icloud`, `$alarms`, `$maps`, `$services`, `$music`, `$notifications`, `$location` | No. `isAvailable()` returns `false` and calls reject with `[unsupported_platform]`. Templates that use one are left out of the template list |

## Security

Scripts, imported archives and network responses are untrusted, as on every platform. The Linux-specific parts:

- **Package files** are opened relative to the package folder with `openat2` (`RESOLVE_BENEATH`, no symlinks, no magic links) and must be regular files with one link. Where the kernel has no `openat2` the path is walked one component at a time with `O_NOFOLLOW`. Traversal, absolute paths, backslashes, symlinks, hard links, case collisions and names that are not UTF-8 are refused. Files are created with mode 0600, folders 0700.
- **Archives** are checked whole before anything is extracted (entry count, file size, expanded size, names), extracted through the same reading of the archive that checked them, into a unique staging folder on the same filesystem, and published with a rename that refuses to replace anything.
- **Network.** Requests go over a small HTTP/1.1 client on rustls. It resolves the host itself, refuses private, loopback and link-local addresses, and connects only to the address it checked. Redirects are followed by hand with the same checks at every hop, and a redirect to another origin does not receive the `Authorization` or `Cookie` header the script set. The system proxy is not used. Requests name the client as `ScriptWidget-Linux/<version>` unless the script sets its own `User-Agent`.
- **Engine isolation.** Package code runs inside the program's process, as on the other platforms: QuickJS exposes no system interface, and memory, stack and time are bounded.
- **Command line output.** `render --output` and `pack` write a private temporary file and rename it; they refuse a symlink at the output name and any output inside the package.
