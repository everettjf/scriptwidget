# ScriptWidget for Linux: what is left

The plan is in [plan.md](plan.md) (Chinese); what was tested is in [testing.md](testing.md).

## Before anything is released

- **Licences of the six display fonts.** The repository records the licence of Inter only (`OFL-Inter.txt`). The six display fonts under `Android/core/src/main/assets/fonts` are built into the Linux program and need their licence files recorded before a release.
- **A real Linux computer.** Everything ran in one virtual machine with a virtual GPU. Not tested: a real GPU, an input method, display scales above 1, several displays, sleep and wake.

## Phases still to do

- **Phase 2: background service and display.** `sw-host`, the commands that need it (`add`, `remove`, `widgets`, `refresh`, `dev`, `peek`, `arrange`, `watch`, `tap`, `move`, `screen`, `theme`, `menu`), the Omarchy plugin (`service` and `bar-widget`), GIF frame cycling, the per-second and per-minute redraw of `<date>`, refresh scheduling.
- **Phase 3: management window** with GPUI and `gpui-kit` (pin the version: it is released weekly).
- **Phase 4: packaging.** GitHub release `linux-v<version>`, AUR package, plugin repository. Remove `Linux/spikes` once phases 2 and 3 have replaced them.
- `docs/platform-support.md` has no Linux column yet; add it when there is something a user can install.

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
- GIF: every frame keeps its own delay (at most 60 frames, 8 MB, 16 million pixels); Windows samples 24 frames. Showing frame N decodes frames 0 to N again: the service has to cache decoded frames.
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

- `clippy` reports style warnings in `sw-render`; CI runs it without failing on warnings.
- AddressSanitizer covers the engine binding tests only.
- The 14 bundled templates that ask the network were not rendered anywhere.
- Not tested: a real `/usr/share/scriptwidget` installation, two `install` commands at once, the `openat2` fallback being chosen by a kernel without it, a filesystem without `RENAME_NOREPLACE`.
