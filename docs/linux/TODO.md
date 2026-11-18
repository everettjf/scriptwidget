# ScriptWidget for Linux: what is left

The plan is in [plan.md](plan.md) (Chinese); what was tested is in [testing.md](testing.md).

## Known limits of the preview

- **Tested on one machine.** Everything a person can see was tested in one aarch64 Omarchy 4.5 virtual machine with a virtual GPU, one 1920×1080 display at scale 1, and a virtual pointer instead of a hand. Display scale 2, a second display with another scale, a display going away, and a light theme were tested there with a virtual second display; a suspend and resume cycle was tested in the kernel's self-resuming test mode, not with real sleep. Composing Chinese with fcitx5 pinyin in the editor was tested there with a virtual keyboard. After a restart of the machine and a login, the service started by itself and the saved widgets were back on the desktop. Not tested: a real computer, a real GPU, and a person typing.
- **The x86_64 archive** was never run on an x86_64 computer. Besides the CI run without a desktop, its programs were run through instruction emulation inside the aarch64 Omarchy 4.5 test machine, against the real desktop there (see [testing.md](testing.md)); that shows the archive is complete and works, not how it behaves on real x86_64 hardware and drivers.
- **ICU.** The programs link the system's ICU 78 by its versioned name. When Arch and Omarchy move to ICU 79 they stop starting until a new archive is built. Fix: link ICU statically, or publish an AUR source package that is rebuilt on the user's machine.
- **Display fonts.** The six display fonts of the other platforms (Apple ][, Larabiefont Free, Monofonto, White Rabbit, OneSlot, Unispace) are not shipped: the repository records no licence for them, and the notice inside `Unispace.ttf` forbids redistribution. Text that asks for one is drawn with Inter. The same files ship in the iPhone, Android and Windows apps; their licences need to be settled there too.
- **The archive is not signed**, and its third-party notices are a hand-written summary, not a generated list of every crate licence.
- **No AUR package and no entry in the Omarchy plugin catalog.** The plugin is installed by `install.sh` from the archive.

## Still to do

- **Lock screen.** Omarchy locks through its own shell and sends nothing on logind, and the plugin does not report it, so the service keeps refreshing behind the lock screen.
- **Screens.** No message tells the service a display went away: a widget on a display that is gone is shown on the first display at the same coordinates, still drawn at the old display's scale until it is moved. Dragging a widget from one display to another has code but never ran.
- **Time zone changes** are not noticed until the next refresh.
- **Management window:** closing it with unsaved changes does not ask (moving to another page does); no "new file" button; the components and API reference pages of the Windows app are missing; changing the refresh interval writes the setting but does not tell the running service; in the test machine the editor's blinking cursor costs a quarter of a core under software rendering.
- **Plugin:** a widget takes the pointer over its whole area, so while widgets are shown on top the windows under them cannot be clicked through them; frames do not pause behind ordinary windows or on the lock screen; the bar entry starts `scriptwidget-studio` without checking that it exists; widgets are not moved when the dock appears later; the Chinese strings were not seen on screen.
- **Service:** real suspend and resume and the path that drops a slow display were not exercised; `doctor` does not ask the plugin for its status.
- `docs/platform-support.md`, the website and Web Studio list Linux; the root README files do not yet.

## Runtime

- **Out of memory is recognised by its message.** A script that ends with the engine's "out of memory", or with a `null` exception (what the engine leaves when it cannot even build the error), is reported as `resourceLimit`. A script that itself throws `null` is therefore reported as a memory-budget error. The exact fix is a flag from the allocator in `sw-quickjs`.
- **A lone UTF-16 surrogate** that reaches Rust becomes U+FFFD; Windows keeps it.
- **`PackageFiles::paths()` cannot fail**, so a package with more than 500 files lists as empty through the trait instead of reporting `too_many_entries`.
- **The driver name in `host.js`** (`__sw_<hex>`) is visible to package code through `Object.getOwnPropertyNames(globalThis)` on every QuickJS host. It only lets a script pump, resolve or time out its own execution; shared with Android and Windows, not changed here.
- **Network:** one connection per request, no keep-alive; brotli bodies are passed through undecoded; a `$weather` request is not cancelled when the execution ends. No request to a real Internet host has been made by a test.
- **Unsupported-API filter** of the template list reads only `main.jsx`, as on Windows, so "Local Weather (Location)" is listed.
- **Remote images** in `render` are fetched under the package's network policy; there is no offline switch, and a tree nested deeper than about 64 elements gets placeholders.
- **`$music` (MPRIS) and `$notifications`** are planned for after the first version.
- **Engine in a separate restricted process** (Landlock, seccomp): planned, not started.

## Painter

Differences from the Windows painter, or things not compared:

- No picture has been compared pixel for pixel with Windows or iPhone; about 25 pictures were looked at by eye.
- Live date slots, motion slots and scrolling-list slots are not ported: Linux draws again instead, and a `<list>` is drawn in place with only its visible tap targets.
- GIF: every frame keeps its own delay (at most 60 frames, 8 MB, 16 million pixels); Windows samples 24 frames. The service caches decoded frames while it draws an animation.
- Images are decoded at full size before being reduced (limit 40 megapixels). HEIC is probably not decodable; not tested.
- Rounded corners of the widget itself are left to the display, as on Windows.
- Gradients interpolate premultiplied (as CSS and Windows; Android does not). Conic gradients use Skia's sweep gradient.
- Drop shadows use a Skia image filter; softness follows Android's formula and was not compared.
- `rotate3d` uses the Windows matrix. SVG mask luminance is taken on non-linear sRGB, as on Android.
- Monospace and serif fonts are the user's fontconfig choices, so widths differ from Windows.
- Painting has no time limit (layout has 8 seconds).
- In "Personal Dashboard" at the medium size the title touches the top edge; not yet checked against the other platforms.
- A machine with no Chinese, Japanese, Korean or emoji font, and `extraLarge` with real templates, were not tested.

## Tests and tooling

- `clippy` reports style warnings in `sw-render`; CI runs it without failing on warnings. CI does not build the management window (`ui` feature); the release workflow does.
- AddressSanitizer covers the engine binding tests only.
- The 14 bundled templates that ask the network were not rendered anywhere.
- Not tested: a real `/usr/share/scriptwidget` installation, two `install` commands at once, the `openat2` fallback being chosen by a kernel without it, a filesystem without `RENAME_NOREPLACE`.
