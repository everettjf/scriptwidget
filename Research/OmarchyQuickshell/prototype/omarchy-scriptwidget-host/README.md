# Phase-0 Omarchy surface smoke test

This is a non-shipping, static Quickshell plugin. It proves only that themed
cards can be drawn on Omarchy's bottom layer without reserving tiling space or
capturing desktop input. It does not execute ScriptWidget packages.

On an Omarchy 4 test machine, install from a checkout of this repository:

```bash
omarchy plugin add /absolute/path/to/omarchy-scriptwidget-host --enable
omarchy restart shell
```

Verify all of the following before starting the Linux runner:

- cards appear above the wallpaper and below normal windows;
- double-click wallpaper actions still work through the transparent surface;
- changing the Omarchy theme updates card colors;
- every monitor gets exactly one correctly scaled card column;
- toggling/restarting the shell leaves no stale layer surfaces.

Remove it with:

```bash
omarchy plugin remove everettjf.scriptwidget-host-research
```

