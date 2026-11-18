# ScriptWidget for Linux: the display protocol

How the background service and a display talk to each other. The contract is sections 4.4 and 4.8 of [plan.md](plan.md) (Chinese); this page writes it out exactly and records every decision the plan left open. Those are marked **Decision**.

A display is whatever puts the pictures on the desktop: today the Omarchy plugin (`Linux/omarchy-plugin`). It never runs or reads package content. It receives picture paths, rectangles and numbers, and sends back numbers and words from fixed lists.

Protocol version: **1**.

## The parts

| Part | What it is |
| --- | --- |
| Service | `scriptwidget host run`, a long-running process of the user's session. Code: `Linux/crates/sw-host` |
| Socket | `$XDG_RUNTIME_DIR/scriptwidget/host.sock` |
| Pictures | PNG files in `$XDG_RUNTIME_DIR/scriptwidget/frames/` |
| Commands | `scriptwidget watch`, `tap`, `move`, `screen`, `theme`, `menu`, `session`: each connects to the socket, sends one request and prints the answer |

**Decision: the service is the `scriptwidget` program itself** (`scriptwidget host run`), not a second program `scriptwidget-host`. One file is installed, and the command line can never be a different version from the service it talks to; every binary links the engine and Skia statically, so a second one would double the installed size. A systemd user unit starts it (`Linux/packaging/systemd/scriptwidget.service`). When the program is installed or linked under the name `scriptwidget-host` it behaves as `scriptwidget host run`.

A display should run the commands, not open the socket itself: the commands are the stable interface. The socket format is written down below for the management window and for tests.

## Starting and stopping

- `scriptwidget host run [--data <dir>]` needs `XDG_RUNTIME_DIR`; there is no fallback to `/tmp`. It prints nothing on standard output; a few lines for the journal go to standard error (identifiers, error kinds and its own paths, never package content or addresses of links).
- Exit codes: `0` after `SIGTERM` or `SIGINT`; `2` when it cannot start (no runtime directory, no runtime files, or a service is already running in this session: the message says "already running").
- A second service in the same session is refused through a lock on `host.lock` (`flock`). The service that holds the lock removes a socket file left by a service that crashed, and all pictures of an earlier run.
- On `SIGTERM` or `SIGINT` the service sends `bye` to every watcher, waits up to one second for those lines to be written, removes the socket and the pictures, and exits.
- The unit is `PartOf` and `WantedBy` `graphical-session.target`. It uses `KillMode=process`: a browser started by a link in a widget, and the management window, are not stopped with the service.

## Events: what `scriptwidget watch` prints

One JSON object a line, UTF-8, each with a string member `event`. A display ignores events and members it does not know.

| Event | Members |
| --- | --- |
| `hello` | `protocol` (integer, 1), `dark`, `arrange`, `peek` (booleans), `service` (the service's version, text) |
| `widget` | `id`, `screen`, `x`, `y`, `width`, `height`, `image`, `version`, `regions`, optional `frames`, `family`, `families` |
| `remove` | `id` |
| `mode` | `arrange`, `peek` |
| `bye` | `reason` |

Examples, exactly as printed:

```
{"event":"hello","protocol":1,"dark":false,"arrange":false,"peek":false,"service":"0.1.4"}
{"event":"widget","id":"5ef2d5c170089ecf","screen":"eDP-1","x":40,"y":40,"width":329,"height":170,"image":"/run/user/1000/scriptwidget/frames/5ef2d5c170089ecf-1d639a55-3.png","version":3,"regions":[{"n":0,"x":16,"y":120,"width":96,"height":34}],"family":"medium","families":["small","medium","large"]}
{"event":"widget","id":"c45467fe6c9c2b4a","screen":"","x":68,"y":68,"width":170,"height":170,"image":"/run/user/1000/scriptwidget/frames/c45467fe6c9c2b4a-1d639a55-1-0.png","version":1,"regions":[],"frames":[{"image":"/run/user/1000/scriptwidget/frames/c45467fe6c9c2b4a-1d639a55-1-0.png","ms":200},{"image":"/run/user/1000/scriptwidget/frames/c45467fe6c9c2b4a-1d639a55-1-1.png","ms":300}],"family":"small","families":["small","medium","large","extraLarge"]}
{"event":"remove","id":"5ef2d5c170089ecf"}
{"event":"mode","arrange":true,"peek":true}
{"event":"bye","reason":"shutdown"}
```

### `hello`

The first line of every connection. A display that reads another `protocol` shows "update ScriptWidget" and parses nothing else.

**Decision: after `hello` the service sends one `widget` event for every widget that has a picture**, immediately, so a display that connects later has the whole state. A widget whose first picture is still being drawn (just after the service started, or just added) is sent when the picture is ready. A display that removes widgets it was not told about again should therefore wait a few seconds after `hello`; a script may take up to five seconds, longer with network requests.

**Decision: after every `hello` the display reports every screen and the theme again** (`screen`, `theme`). The service remembers the last report across restarts (in its cache directory) so that it draws at the right scale at once, but the display is the authority.

### `widget`

A new widget, or a change to one. Every member is always present except `frames`.

| Member | Meaning |
| --- | --- |
| `id` | 16 lower-case hexadecimal digits, random, made by the service |
| `screen` | The display's own name of the screen, as the display reported it in `move`. **Decision:** empty text until the display has placed the widget; the display then uses its primary screen. A name the display does not know is treated the same way |
| `x`, `y` | Integers: offset of the widget's top-left corner from the screen's top-left corner in logical pixels |
| `width`, `height` | Integers: logical size. 170×170, 329×170, 329×345 or 639×345 |
| `image` | Absolute path of a PNG. Its pixel size is the logical size times the screen's scale |
| `version` | Integer from 1; one more for every new picture of this widget since the service started |
| `regions` | `[{n, x, y, width, height}]`: tappable areas, integers in logical pixels from the widget's top-left corner, in the order they were painted. **Decision:** where two overlap, the later one is on top. `n` is the number to send in `tap`. At most 256. Nothing else is told about a region |
| `frames` | Only for a widget that moves: `[{image, ms}]`, 2 to 60 entries. Show each `image` for `ms` milliseconds, then start again. `image` beside it is the first frame |
| `family` | **Addition.** `small`, `medium`, `large` or `extraLarge`: the current size, for the menu |
| `families` | **Addition.** The sizes the package supports, for the menu. The service refuses a resize to any other |

A `widget` event is sent when the picture changed (new `version` and new `image`) and when only the place changed (after `move`: same `version`, same `image`). **Decision:** a script that runs again and draws the same picture produces no event. A `menu` resize is answered with a `widget` event, also when the widget already has that size.

`version` starts again at 1 when the service restarts; the path never repeats (see below), so a display should key its image cache on the path, or on the connection and the version.

### `mode`

Sent when `arrange` or `peek` changed. Both are state of the service, not saved across restarts; a new service starts with both off.

**Decision: turning arrange on turns peek on**, because on the bottom layer a drag ends where the pointer reaches a window. Turning arrange off puts peek back to what it was before, unless `peek` was set while arranging; then that choice stays.

### `bye`

The last line. Reasons:

| `reason` | Written by | Meaning | Exit code of `watch` |
| --- | --- | --- | --- |
| `shutdown` | the service | It was asked to stop | 0 |
| `not-running` | `scriptwidget watch` | There was no service to connect to. This is the only line | 69 |
| `lost` | `scriptwidget watch` | The connection ended without a `bye`: the service was killed, or it dropped this watcher for being too far behind | 69 |

**Decision:** `watch` always ends its output with a `bye` line, so a display has one thing to look for; when there is no service it also prints `error: [service.unavailable] …` on standard error with how to start it. After any `bye` the display keeps the last pictures (they are in its memory; the files are gone) and runs `watch` again after a few seconds.

A watcher that has more than 1024 events waiting is dropped.

## Pictures

- Directory `$XDG_RUNTIME_DIR/scriptwidget/frames/`, mode 0700; files mode 0600.
- **Decision: names.** `<id>-<run>-<version>.png`, and `<id>-<run>-<version>-<frame>.png` for the frames of an animation. `<run>` is eight hexadecimal digits, random for each start of the service. A path is therefore never used twice, not even across restarts: a display that is told the same path again does not load it again (checked with Quickshell). Names consist of letters, digits, `-` and `.` only.
- A picture is written under a hidden name (`.job-….tmp`) and renamed; a display never sees half a file.
- **Decision: when old pictures go.** The protocol has no acknowledgement, so a replaced picture stays for 5 seconds after the event that replaced it, then it is deleted. A display must have opened a picture within 5 seconds of being told about it. The pictures of a removed widget go the same way. All pictures are deleted when the service stops and when it starts.

## Commands of the display

All are argument vectors; nothing goes through a shell. Each prints one JSON report on standard output (`ok`, `status`, `error: {kind, message}` and the members of the service's answer) and exits with 0, or with 69 when the service is not running, 2 when an argument or an identifier is wrong, 1 when the package is at fault (a link that may not be opened, a size the package does not support).

| Command | Meaning |
| --- | --- |
| `scriptwidget tap <id> <n> [<version>]` | Region `n` was tapped. **Addition:** with `<version>` the number is looked up in the table of that picture, which the service keeps as long as the picture's file (5 seconds after it was replaced); a picture older than that is refused with `version.stale`. Without it, the current picture's table is used |
| `scriptwidget move <id> <screen> <x> <y>` | The widget was dropped at `x`, `y` on `screen`. Negative numbers are accepted as they are (no `--` needed); a fraction is rounded. Values are kept between −100000 and 100000. On a screen whose size was reported the widget is kept inside the screen. Answered with a `widget` event to every watcher |
| `scriptwidget screen <name> <scale> <width> <height>` | A screen: its name (letters, digits, `.`, `_`, `:`, `-`, at most 64), its scale as a decimal number from 0.5 to 8, and its logical size. At most 16 screens. Widgets on a screen whose scale changed are drawn again at the new scale (the script does not run) |
| `scriptwidget theme <dark\|light>` | The theme. A change runs every widget again |
| `scriptwidget menu <id> <word>` | `resize-small`, `resize-medium`, `resize-large`, `resize-extraLarge`, `edit`, `remove`, `refresh`. Any other word is refused before anything is looked up |
| `scriptwidget session <locked\|unlocked>` | **Addition**, see "Lock and sleep" |
| `scriptwidget peek [on\|off\|toggle]`, `scriptwidget arrange [on\|off\|toggle]` | Without a word: toggle. Answered with a `mode` event to every watcher when something changed |

**Decision: there is no command that says a screen went away.** A widget on a screen the display no longer has keeps its saved place; the display shows it on its primary screen until it is moved.

### What a tap does

The service looks `n` up in its own table for that picture. The table holds what the shared renderer recorded for the element; the request carries only the number.

| Element | Effect | `action` in the answer |
| --- | --- | --- |
| `<button action="reload">` | The script runs again | `reload` |
| `<button actionID=…>` | The action runs if the manifest declares it (otherwise nothing runs), then the script runs again | `button` |
| `<button onClick="name">` | The function runs if the name is a plain identifier, then the script runs again | `button` |
| `<toggle>` | The new state is saved under its `stateKey` if the package has the `storage` permission, the action or function runs, then the script runs again | `toggle`, with `value` |
| `<link url=…>` | `http`, `https` and `mailto` are opened with `xdg-open <url>`, where `<url>` is the canonical form of the parsed address. Every other scheme is refused with `link.refused` | `link` |
| `<link url="scriptwidget:…">` | The management window is started; nothing of the address is passed on | `application` |

This is the behavior of the Windows host (`AppHost.OnClick`, `AppHost.Perform`, `Links.Open`). A manifest that is present but unreadable, or whose `actions` or `controls` are malformed, runs nothing.

### `menu … edit`: the hook

The service starts `scriptwidget-studio --edit <package name>`, an argument vector, where the name is the one the service finds for the widget's package in the library. The program is looked for beside the `scriptwidget` program, then on `PATH`. When it is not installed the answer is the error `studio.unavailable`.

## Lock and sleep

Refresh is paused while the session is locked and everything runs once when it is unlocked; everything also runs once after the machine wakes and after the wall clock is set.

- **Sleep and clock**: the service holds a timer on the realtime clock that the kernel cancels when the clock is set or the machine wakes (`TFD_TIMER_CANCEL_ON_SET`), and it also reads logind's `PrepareForSleep`. Its deadlines are on `CLOCK_BOOTTIME`, which counts the time asleep, so whatever became due during sleep is overdue on waking.
- **Lock from logind**: the service runs `gdbus monitor --system --dest org.freedesktop.login1` as a child and reads `Lock`, `Unlock` and `LockedHint` of this user's sessions.
- **Lock from the display. Addition:** `scriptwidget session locked` and `scriptwidget session unlocked`. Omarchy locks with the shell's own lock screen (`WlSessionLock`), which sends nothing through logind, so on Omarchy the service only learns of a lock when the display says so. The session counts as locked while either source says so. A display that cannot tell needs to do nothing: the service then keeps refreshing behind the lock screen.

## Other commands that use the service

| Command | What it does |
| --- | --- |
| `scriptwidget add <package> [--family <name>]` | Places a widget of an installed package (by its name in `scriptwidget list`). Without `--family`: `medium` when the package supports it, otherwise its first size. Answer: `id`, `package`, `family`. At most 64 widgets. **Decision:** the new widget has `screen` empty and is offset 40 pixels plus 28 for each widget already placed (wrapping after 8) |
| `scriptwidget remove <id>` | Removes it |
| `scriptwidget widgets` | `widgets: [{id, package, installation, installed, family, screen, x, y, width, height, version, image, frames, regions, scale, runs, busy, error}]` |
| `scriptwidget refresh [<id>] [--package <name>]` | Runs one widget, the widgets of a package, or all of them again. Answer: `refreshed` |
| `scriptwidget dev <dir> [--family <name>] [--adopt]` | See below |
| `scriptwidget doctor` | Its `service` check is `passed` with the service's status when it runs, `notRun` when it does not |

### `dev`

**Decision: `dev` sends no path to the service.** The command itself looks at the folder a few times a second (modification times and sizes; no inotify dependency, and the service watches nothing). When something changed and the folder holds still, it copies the folder into the library through the package store (the same path, link and size rules as `install`; files that are gone from the folder are removed from the installed copy) and asks the service to refresh the widgets of that package by name.

- The installed package has the folder's name. The first run creates it and places one widget if the package has none on the desktop.
- A package of that name that `dev` did not create from this folder is not touched: the command fails with `dev.package_exists`. `--adopt` takes it over.
- Output: one JSON object a line. `{"event":"ready","package","installation","widgets":[ids],"added"}` once; `{"event":"synced","package","written":[paths],"removed":[paths],"refreshed"}` for every copy; `{"event":"error","code","message"}` when the folder cannot be copied at the moment (it keeps watching); `{"event":"bye","reason":"not-running"}` and exit code 69 when the service has gone.
- A folder with a compile error is still copied: the widget shows the error card.

## The socket

`$XDG_RUNTIME_DIR/scriptwidget/host.sock`, a stream socket, mode 0600 in a directory of mode 0700. For every connection the service asks the kernel for the peer's user (`SO_PEERCRED`) and serves only its own user; anyone else, root included, gets `{"ok":false,"error":{"code":"peer.refused",…}}` and the connection is closed.

A request is one line: a JSON object with `op` and the members of that operation, at most 4096 bytes. Unknown operations, unknown members, wrong types and values out of range are refused. Requests name only package names, widget identifiers, integers and words from fixed lists; nothing received is executed or used as a path.

| `op` | Members |
| --- | --- |
| `watch` | none. The connection becomes the event stream; what the client sends afterwards is ignored |
| `status` | none |
| `widgets` | none |
| `add` | `package` (name), optional `family` |
| `remove` | `id` |
| `refresh` | optional `id` or optional `package` (name), not both |
| `peek`, `arrange` | `state`: `on`, `off`, `toggle` |
| `tap` | `id`, `n` (0 to 4095), optional `version` |
| `move` | `id`, `screen`, `x`, `y` (integers) |
| `screen` | `name`, `scale` (integer, thousandths: 1500 is 1.5), `width`, `height` |
| `theme` | `mode`: `dark`, `light` |
| `menu` | `id`, `word` |
| `session` | `state`: `locked`, `unlocked` |

The answer is one line: `{"ok":true,…}` or `{"ok":false,"error":{"code":"…","message":"…"}}`. A connection may send several requests, one after the other. Codes: `request.invalid`, `request.too_long`, `peer.refused`, `service.busy`, `widget.unknown`, `region.unknown`, `version.stale`, `package.unknown`, `family.unsupported`, `widgets.limit`, `screens.limit`, `link.refused`, `link.unavailable`, `studio.unavailable`.

Limits: 32 connections at once (one more is told `service.busy`), 10 seconds to send a request, 8 lines that are not requests before the connection is closed.

## Refresh

| When | What happens |
| --- | --- |
| Every `refreshMinutes` of `settings.json` in the data directory (default 15, kept between 5 and 1440; the file is read again when it changes) | The script runs |
| At the package's next timeline transition, when that is sooner | The script runs |
| A `<date>` with style `timer`, `relative` or `offset` | The same tree is drawn again just after every full second; the script does not run |
| A `<date>` with style `time` | The same tree is drawn again just after every full minute |
| `refresh`, `menu … refresh`, a tap, a new theme, unlock, waking, the clock being set | The script runs |
| A new scale of the widget's screen | The same tree is drawn again |

The rules for `<date>` are those of the Windows host (`AppHost.NextRedraw`). One difference from Windows: there the interval starts again after every redraw, so a widget with a running timer never reaches it; here only a run of the script starts it again.

**GIF.** The service decodes and draws; the display only cycles pictures. Every frame is the whole widget, drawn through the full layout. At most 60 frames; all frames of one cycle together at most 32 million pixels, otherwise only the first frame is shown. **Decision:** with several animated GIFs in one widget there is a picture for every moment one of them changes, over the length of the longest GIF, and the cycle starts again there; when that would be more than 60 pictures only the longest GIF moves.

## Files the service keeps

| File | Content |
| --- | --- |
| `<data>/widgets.json` | `{"version":1,"widgets":[{"id","package","family","screen","x","y"}]}`. `package` is the installation identity of the package (as in `scriptwidget list`), which stays the same when the package is renamed. Mode 0600, replaced with a rename. At most 64 entries; entries that are not valid are dropped when read |
| `<cache>/display.json` | The screens and the theme the display last reported |
| `<data>/settings.json` | Read only: `refreshMinutes` |

## How it runs

Threads and channels, no asynchronous runtime. One loop owns all state and never does anything slow; one worker thread runs scripts and draws, one widget at a time, as the Windows host does; the socket has one thread that accepts and one for each connection (two for a watcher). Package code runs inside the service process in a fresh QuickJS context with bounded memory, stack and time (plan, section 6). Between refreshes every thread sleeps in a blocking call.
