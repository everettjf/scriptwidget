# ScriptWidget for Omarchy

The display end of ScriptWidget on [Omarchy](https://omarchy.org): an Omarchy shell plugin that shows the widgets ScriptWidget draws on the desktop layer, passes clicks and drags back to it, and adds an entry to the bar.

The plugin draws nothing itself and runs no widget code. The `scriptwidget` program and its background service do that; the plugin shows the PNG pictures they write and tells them what the pointer did. Without ScriptWidget installed the plugin only shows a bar entry that says so.

Status: preview, shipped in the Linux archive (see [ScriptWidget for Linux](../../docs/linux/README.md)). It was tested against the stand-in in `tests/` and, on the Omarchy 4.5 test machine, against the real background service (see the [test notes](../../docs/linux/testing.md)).

## Files

| File | What it is |
| --- | --- |
| `manifest.json` | Plugin `com.atomsprout.scriptwidget`, kinds `service` and `bar-widget`, `keepLoaded` |
| `Service.qml` | Runs `scriptwidget watch`, checks every event, keeps the list of widgets, sends the commands, draws the arrange menu |
| `WidgetWindow.qml` | One widget: a layer-shell window with the picture, taking the pointer only on its tap regions |
| `ArrangeWindow.qml` | Arrange mode: one window per screen in which the widgets can be dragged |
| `BarWidget.qml` | The bar entry |
| `i18n/` | The strings, in English |
| `tests/` | A stand-in for `scriptwidget` and the checks. Not part of the installed plugin |

## Installing for development

```
mkdir -p ~/.config/omarchy/plugins/com.atomsprout.scriptwidget
rsync -a --delete --exclude tests Linux/omarchy-plugin/ ~/.config/omarchy/plugins/com.atomsprout.scriptwidget/
omarchy plugin validate ~/.config/omarchy/plugins/com.atomsprout.scriptwidget
omarchy plugin enable com.atomsprout.scriptwidget
omarchy restart shell
```

**Restart the shell after changing the plugin.** The manifest sets `keepLoaded`, which makes the shell keep the service alive when it reloads plugins (it reloads all of them whenever any local plugin file changes); without it every such reload would close and reopen all widgets. The price is that an edited `Service.qml`, `WidgetWindow.qml` or `ArrangeWindow.qml` is not picked up by the reload. On Omarchy 4.5.0 turning the plugin off and on did not load the new code either; only `omarchy restart shell` did.

The folder may also be a symbolic link to `Linux/omarchy-plugin`; `omarchy plugin validate` refuses links inside the folder, not the folder itself.

### Environment variables

Read from the environment of the shell process with `Quickshell.env`, for development and tests. The shell is started by Hyprland and inherits its environment, so set them with `hyprctl eval 'hl.env("NAME", "value")'` and restart the shell. An empty value counts as not set.

| Variable | Default | Meaning |
| --- | --- | --- |
| `SCRIPTWIDGET_PLUGIN_BIN` | `scriptwidget`, found on `PATH` | The program to run |
| `SCRIPTWIDGET_PLUGIN_STUDIO_BIN` | `scriptwidget-studio`, found on `PATH` | The management window |
| `SCRIPTWIDGET_PLUGIN_FRAMES` | `$XDG_RUNTIME_DIR/scriptwidget/frames` | The only directory pictures are read from |

## What it does

The contract is section 4.8 of [`docs/linux/plan.md`](../../docs/linux/plan.md). The plugin runs `scriptwidget watch` and reads one JSON event per line.

- **Widgets.** Each `widget` event becomes one layer-shell window, namespace `scriptwidget`, on the bottom layer (above the wallpaper, below every window), on the screen the event names or the first screen. It is transparent, reserves no space and never takes the keyboard.
- **Taps and the menu.** A widget window takes the pointer over its whole area. A left click in a tap region runs `scriptwidget tap <id> <n>` (where regions overlap, the one named last wins); a left click elsewhere on the widget does nothing. A right click anywhere on the widget opens its menu: `resize-small`, `resize-medium`, `resize-large`, `resize-extraLarge`, `edit`, `refresh` and `remove` run `scriptwidget menu <id> <word>`, and "Move widgets…" / "Done moving" runs `scriptwidget arrange`.
- **Show on top** (`mode.peek`). The same windows move to the overlay layer and back.
- **Arrange** (`mode.arrange`). The widget windows are replaced by one window per screen, namespace `scriptwidget-arrange`, that shows the same pictures with an outline. A widget can be dragged; letting go runs `scriptwidget move <id> <screen> <x> <y>`. Within 40 px of an edge of the usable area a widget snaps to 16 px from it. The usable area is the screen without the bar and without the Omarchy dock: the plugin asks Hyprland (`hyprctl -j layers`) where the `omarchy-dock` layer is each time arrange mode starts and each time a drag starts. A right click opens the same menu as outside arrange mode.
- **Frames.** A widget with `frames` cycles through them. The cycle stops while a fullscreen window is on the workspace in front of the widget (and "show on top" is off), while arranging, and while the service is not running. It does not stop when ordinary windows cover the widget or when the session is locked: Quickshell has no cheap signal for either.
- **Reports.** After every `hello`, and when they change: `scriptwidget screen <name> <scale> <width> <height>` for each screen (the scale Hyprland reports; logical size) and `scriptwidget theme <dark|light>`, judged from the brightness of the theme's background color.
- **Bar entry.** Left click opens the management window. Right click opens a card with "Show widgets on top" and "Arrange widgets", which run `scriptwidget peek` and `scriptwidget arrange` and show the state the last `mode` event gave.
- **When something is wrong.** `watch` ends, or cannot be started: the last pictures stay, the plugin tries again after 2, 4, 8, 16 and then every 30 seconds, and the bar entry is dimmed and says that ScriptWidget is not running, or not installed. `hello` with a protocol other than 1: nothing is shown on the desktop and the bar entry says "Please update ScriptWidget".
- **Status.** `omarchy-shell com.atomsprout.scriptwidget status` prints one line of JSON: `protocol`, `status` (`starting`, `running`, `stopped`, `missing`, `outdated`), `arrange`, `peek`, `dark`, the number of `widgets`, how many are `animating`, and whether the `menu` is open. It changes nothing.

### What the plugin expects of the service, beyond the table in the plan

- Every line of `watch` is a JSON object with a string field `event`.
- `id` matches `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`. Other ids are ignored.
- `x`, `y`, `width`, `height` and the fields of `regions` are JSON numbers (not strings); they are rounded to whole logical pixels. `x` and `y` are measured from the top left corner of the screen, bar included. `regions` are measured from the top left corner of the widget. `width` and `height` are 1 to 8192.
- `image` is an absolute path below the frames directory that ends in `.png`; every path component consists of letters, digits, `.`, `_` and `-`. Anything else is ignored, and so is the widget.
- A new picture has a new `version`. The file name may stay the same or change.
- `frames`, when present, has 2 to 60 entries `{image, ms}`; `image` is still required and is shown where animation is off. One invalid frame turns the animation off. `ms` below 20 is taken as 20.
- After `hello` the service names every widget again within 12 seconds (a widget whose script is still running has no picture yet and is named late). Widgets the plugin still shows from before and that are not named by then are removed.
- `scriptwidget peek` and `scriptwidget arrange` without arguments switch the mode over, and the service answers with a `mode` event.
- The service answers `move`, and a `menu` resize, with a `widget` event. Until then the picture stays where it was dropped, for at most 3 seconds.
- `watch` ends with a non-zero exit code or any other way when there is no service; the plugin does not look at the code.
- At most 64 widgets, 256 regions per widget, and 262144 characters per line.

## Security

The plugin runs inside the Omarchy shell without a sandbox, so it is kept small:

- It never reads a package and never receives package content: only picture paths, numbers and ids.
- Every command is an argument vector (`Quickshell.execDetached`, `Process`); no shell string is built anywhere. The words it sends are an id it was given and checked, a number, a screen name from Quickshell, or a word from a fixed list.
- It opens only `.png` files inside the frames directory (see above), and nothing the events name outside it. Qt decides the image format from the file's content, not its name, so the directory must stay writable by the service only (mode 0700).
- All text it shows is its own, with `textFormat: Text.PlainText`.
- It runs three programs: `scriptwidget`, `scriptwidget-studio` and `hyprctl -j layers`.

## Tests

`tests/check.sh` runs on a live Omarchy session (one monitor, scale 1) against `tests/scriptwidget`, a stand-in that speaks the protocol, draws pictures with ImageMagick and logs every command it receives. `tests/pointer.py` is a virtual pointer through `/dev/uinput` and needs `sudo` without a password. See the head of `check.sh` for what it changes on the machine and puts back.

```
rsync -a --delete Linux/omarchy-plugin/ testmachine:sw-plugin/
ssh testmachine 'bash ~/sw-plugin/tests/check.sh'
```

`tests/out/` holds the screenshots and the output of the last run on the test machine.

## Known limits

- Not tested: display scales above 1, more than one monitor (including dragging a widget to another monitor), a bar on another edge than the top, a third-party bar, right-to-left languages.
- In arrange mode the pictures are on the same layer as before (bottom, or overlay with "show on top"). On the bottom layer a drag ends where the pointer reaches a window, the bar or a notification, because the compositor gives the pointer to that surface.
- The dock is only avoided where Hyprland reports its layer. Widgets are not moved when the dock appears later or changes edge.
- The cycle of frames does not pause behind ordinary windows or on the lock screen.
- A click on the bar entry starts `scriptwidget-studio` without checking that it exists.
- There is no command that tells the service a screen went away.

## License

Apache License 2.0, the same as the rest of the repository. See `LICENSE`.
