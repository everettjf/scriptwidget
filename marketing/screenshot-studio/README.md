# App Store Screenshots — Editor Template

A pre-built Next.js + ShadCN editor for generating App Store and Google Play screenshots. Scaffolded by the `app-store-screenshots` skill.

## Quick start

```bash
bun install   # or pnpm / yarn / npm
bun dev       # http://localhost:3000
```

## What's inside

- **Connected canvas editor** (`src/components/editor/`) — every screen sits on one horizontal canvas, so phones, captions, and other elements can be dragged across screen boundaries and exported as split crops when Connected mode is enabled.
- **Screen controls** — drag-to-reorder screens, click-to-edit text, screenshot drop targets, per-screen layout switcher, dark/light toggle.
- **Image overlays, fonts, backgrounds and undo** — PNG/JPG overlay elements, a live screenshot font menu (with font import), per-screen custom backgrounds, and toolbar Undo/Redo. See [Editor controls](#editor-controls).
- **Device frames** (`src/components/editor/device-frames.tsx`) — iPhone (PNG mockup), iPad, Apple TV, Apple Watch, CarPlay head unit, Mac window, Android phone, Android tablet (portrait + landscape), feature graphic.
- **Auto-save (git-trackable)** — every change is persisted within ~600ms to **`app-store-screenshots.json`** at the project root (via `/api/project`) **and** mirrored to `localStorage` as an instant-paint cache. Commit `app-store-screenshots.json` and you can `git clone` to another machine and resume exactly where you left off.
- **Multi-device decks** — iOS (iPhone, iPad, Apple TV, Apple Watch, CarPlay), Mac, and Android decks live side by side; switching the platform tab keeps each tab's last device.
- **One-click export** — bulk PNG export at any required App Store / Play Store resolution using `html-to-image`; each PNG is rendered from the current connected or isolated deck mode.
- **Project migration** — older `app-store-screenshots.json` files are migrated on load. Existing per-slide transforms remain valid, and connected crops become available without rewriting the deck by hand.
- **Legacy-safe mode** — pre-v2 projects opened directly in the editor start in isolated-screen mode first, then can opt into connected crops with the toolbar's Connected/Isolated control. Skill-run in-place migrations keep legacy decks isolated unless the project had already explicitly opted into connected canvas.

## Adding screenshots

Two ways:

1. **Drop a file in the inspector** — drag-and-drop or click Pick. The file is sent to `/api/upload`, hashed, and written to `public/screenshots/uploaded/<hash>.png`. The slide stores the resulting `/screenshots/uploaded/...` path, so commit those files alongside `app-store-screenshots.json` and the screenshots survive a `git clone`.
2. **Reference a static file** — put PNGs under `public/screenshots/{platform}/{device}/{locale}/` and reference them by path. Default sample slides expect:
   - `public/screenshots/apple/iphone/en/...`
   - `public/screenshots/apple/ipad/en/...`
   - `public/screenshots/apple/{tvos,watchos,carplay}/en/...` for Apple TV, Apple Watch and CarPlay decks
   - `public/screenshots/apple/mac/en/...`
   - `public/screenshots/android/phone/en/...`

Update the matching `screenshot` fields in `app-store-screenshots.json` to point at whatever filenames you choose.

## Exporting

The toolbar dropdown lists every Apple/Google-required size for the current device. Click **Export bundle** to download a zip. In Connected mode, each PNG is clipped from the connected canvas, so an element that straddles two screens appears split exactly where you placed it. In Isolated mode, each screen clips its own elements and legacy offscreen content cannot leak into neighboring exports.

Exports lock the editor through preparation and bundling and render a fixed project snapshot. Referenced images that cannot be loaded stop the export with an error; empty screenshot fields still produce the existing placeholder warning.

Each screen is rendered once per locale at canvas resolution (`src/lib/export-render.ts`) and scaled to every size; slots whose aspect differs slightly are cover-scaled rather than stretched. Before saving, the exporter redraws until every visible screenshot has painted, because WebKit decodes images inside the html-to-image SVG asynchronously and a single draw can leave device screens blank. If a screenshot never appears, a toast names the screen.

CarPlay has no App Store Connect slot of its own: the CarPlay deck is a head-unit frame on a landscape iPhone canvas and exports landscape iPhone sizes for upload into the iPhone slot.

Mac is its own platform tab because App Store Connect lists macOS separately from the iOS app. The Mac deck designs at 2880×1800 and exports the four 16:10 Mac App Store sizes (2880×1800, 2560×1600, 1440×900, 1280×800) to `macos/mac/<WxH>/<locale>/`. The Mac window's content area is exactly 16:10, so a full-screen 16:10 capture fills it uncropped.

## Editor controls

### Themes and backgrounds

The toolbar **Theme** menu recolours the whole deck (backgrounds, text, accents); it doesn't touch copy, layouts or screenshots. Each screen's **Background** control in the inspector picks the theme background, the theme's alternate (dark/light) background, or a **custom colour** (colour picker or hex). A custom colour applies to that screen only and is saved as `backgroundColor` on the slide. When the theme's text or label colour would be hard to read on it (below a 4.5:1 contrast ratio for text, 3:1 for the label), the caption switches to the theme's other text colour, or to near-black / white. Text elements you've given an explicit colour keep it.

### Screenshot fonts

The toolbar font menu sets the typeface of the screenshot canvas and exports (not the editor UI). **Inter (default)** is the template font and what projects without a `fontId` use. **System Sans** and **Georgia** are available everywhere; **Avenir Next**, **Helvetica Neue**, **Futura**, **Baskerville**, **Palatino**, **Optima** and **American Typewriter** are macOS system fonts that fall back to similar faces elsewhere, so export on the machine you designed on.

**Import font…** at the bottom of the menu takes a licensed WOFF2, WOFF, TTF or OTF file (16 MB max). `/api/upload-font` checks the file's magic bytes and stores it as `public/fonts/imported/<hash>.<ext>`; the project saves it as `importedFont` with `fontId: "self-hosted"`. That font folder is gitignored (font licences often forbid redistribution); keep the file alongside the project JSON if you move the project, or screenshot text falls back to a generic sans-serif. Once imported, the font is listed in the menu under its file name, and it is loaded and embedded before every export.

### Image overlays

In the inspector's **Elements** card, click **Image**, then **Pick** (or drop) a PNG/JPG. Uploads go through `/api/upload` into `public/screenshots/uploaded/`, like screenshots. The first image sizes the overlay frame to its aspect ratio; after that you can drag, resize, rotate (canvas handle or slider), restack, choose **Fill frame** (crop) or **Whole image**, and fade one edge into the background. In Connected mode overlays can cross screen edges like other elements. Overlays are saved per screen as `imageElements`, and the exporter waits for them to paint just like device screenshots. The Play Store feature graphic has a fixed icon + name + tagline layout, so it doesn't take overlays or text elements.

### Undo and redo

The toolbar arrows, `⌘Z` / `Ctrl+Z` and `⇧⌘Z` / `Ctrl+Shift+Z` (or `Ctrl+Y`) step through the last 50 edits of the session: copy, layouts, element moves, text sizes, backgrounds, fonts, themes, overlays and resets. Rapid changes (typing, dragging a slider) collapse into one step. Switching platform, device, orientation or locale isn't an edit, so it doesn't use up an undo step; undoing an edit takes you back to the deck it was made on. While a text field is focused the shortcuts undo that field's typing instead. History resets on reload.

## Customizing

| Where | What |
|-------|------|
| `src/lib/constants.ts` | Canvas dimensions, export sizes, frame ratios, themes, screenshot fonts, locales |
| `app-store-screenshots.json` | Canonical starter project: app name, current device, connected-canvas mode, slide copy, screenshots, and transforms |
| `src/lib/defaults.ts` | Fallback/reset state used when no project file or local cache exists |
| `src/components/editor/slide-canvas.tsx` | Add new layouts and connected-canvas element rendering |
| `src/components/editor/device-frames.tsx` | Tweak device chrome (bezel radii, camera dots) |
| `src/app/layout.tsx` | Swap the font (`next/font/google`) |

## Notes

- `mockup.png` is the iPhone bezel overlay; replacing it requires re-measuring the `PHONE_SCREEN` constants.
- Image preloading converts every static path to a base64 data URI before exports run, and export retries paths that were previously missing. `export-render.ts` then waits for those images to paint in the render (see Exporting).
- Reset via the toolbar's circular arrow icon clears in-memory state and reloads the default screens. To wipe disk state too, delete `app-store-screenshots.json`.
- **Persistence model** — the canonical state lives in `app-store-screenshots.json` (git-tracked). On load, the editor reads localStorage first for instant paint, then overwrites with the file contents if present; if the file endpoint is unavailable, autosave is blocked so stale cache cannot overwrite disk. On save, both are written. File saves are serialized, and the server replaces the JSON atomically so overlapping edits cannot leave a partial file. Invalid project shapes are rejected without overwriting the project. If you ever see a conflict, the file always wins.
- **Migration model** — schema v1 projects do not need a manual conversion. On first load, the editor upgrades localized text and transform records, writes `schemaVersion: 2`, preserves all existing screens, and keeps `connectedCanvas: false` so old offscreen/clipped elements export exactly as isolated screens. Turn on **Connected** in the toolbar when you want elements to cross screen edges. Explicit skill migrations preserve an existing `connectedCanvas` choice, otherwise they keep legacy decks isolated too.
- **Custom themes** — if a project file references a theme id that is not present in `src/lib/constants.ts`, the editor falls back to `clean-light` and shows a warning. Merge custom `THEMES` entries during in-place upgrades.
