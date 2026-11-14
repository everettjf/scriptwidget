# Android UI review (build 8)

A walk through every screen on a Pixel 6 (Android 17) on 13 November 2026, what was wrong, and what changed. The aim is the shortest path from opening the app to a widget on the home screen.

## The path a new user takes

1. Open the app: **My Widgets** shows six starter widgets, drawn as they will look.
2. Tap one: the widget's page shows it at each size, with **Add to home screen** as the main button.
3. The launcher's dialog shows the widget itself; confirm and it is on the home screen.

To get more: **Templates** and **Gallery** are one tap away in the bottom bar, and every template shows a picture before it is added.

## Findings and changes

| Area | Before | Now |
| --- | --- | --- |
| App icon | A blue square with `</>`, unlike iPhone and Mac | The iOS artwork, scaled into the adaptive icon's safe zone, with a themed (monochrome) silhouette |
| Colours | Followed the wallpaper, so the app could be pink or green | One neutral light and dark scheme with a blue accent; the widgets carry the colour |
| Navigation | One list; Templates, Gallery and Settings were behind a sheet or a gear | Bottom bar: My Widgets, Templates, Gallery, Settings |
| My Widgets | Previews stuck to the left of each cell; empty library showed two lines of text | Cards that fill the grid; touch and hold for Add to home screen, Edit code, Improve with AI; an empty state with two buttons; a hint about placing widgets until one is placed |
| New widget | Five choices, two of them now tabs | Four: from a template, AI, blank, import |
| Templates | A text list of 141 names; tapping one added it at once | A grid of live previews with search; tapping opens a larger preview and "Add to My Widgets". Templates that fetch from the network are not run while browsing |
| Widget page | "Edit code" was the main button; the parameter field sat in the middle unexplained; AI was in the overflow menu | "Add to home screen" first, then Edit code and Improve with AI; the parameter is a collapsed row with an explanation; permissions have a heading; errors and logs are titled |
| Launcher dialog | Showed the app icon | Shows the widget at the chosen size |
| Choosing a widget from the home screen | A text list with radio buttons, then Done | Previews at the size being placed; one tap chooses. The parameter is optional and folded away |
| Editor | Preview was always medium; no sign that Save worked | Small, Medium, Large switch; "Saved" after Save and run |
| Settings | Four rows for the refresh interval; no privacy policy link | One row of choices; privacy policy, website and source code under About |

One fault was found on the way: after "Add to home screen" the remembered choice stayed for two minutes, so a widget added from the launcher in that time was bound to the same package without asking. The choice is now cleared when the launcher reports the new widget.

## Not changed

- The Studio editor's own toolbar (Layout, Theme, Assets) is shared with iPhone and Mac.
- Gallery, AI, System Access, Controls and Live Activities keep their layout; only colours and navigation changed.
- The status bar keeps its debug icons in the store screenshots; they come from the test phone.

## Checked on the device

Every screen above was opened on the Pixel 6 in light and dark mode. A widget was placed from the widget page (medium and small), an unconfigured widget on the home screen was tapped and bound from the picker, and a template was added from its preview sheet. The app's instrumented suite passed afterwards (60 tests, the two that need a key or a push wait skipped), as did the JVM tests. Tablets, other launchers and other vendors' phones were not checked.
