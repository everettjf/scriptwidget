# ScriptWidget for Omarchy (shell plugin)

The [Omarchy](https://omarchy.org) shell plugin of [ScriptWidget](https://github.com/everettjf/scriptwidget): it shows the desktop widgets that ScriptWidget draws, passes clicks back to it, and adds an entry to the bar.

The plugin runs no widget code and draws nothing itself. It needs ScriptWidget for Linux installed and its background service running; without them it only shows a bar entry that says so.

## Install

1. Install ScriptWidget, either way:
   - From the AUR-style package attached to each [release](https://github.com/everettjf/scriptwidget/releases) (tag `linux-v…`): download `PKGBUILD` and `scriptwidget-bin.install` into a folder and run `makepkg -si`, then `systemctl --user enable --now scriptwidget.service`.
   - Or from the archive of the same release: unpack it and run `sh install.sh`. The archive already installs and enables this plugin; you do not need this repository.
2. Add the plugin:

   ```
   omarchy plugin add https://github.com/everettjf/omarchy-scriptwidget.git --enable
   omarchy restart shell
   ```

Update it with `omarchy plugin update com.atomsprout.scriptwidget`, then `omarchy restart shell`. Keep it at the same version as ScriptWidget (`scriptwidget --version`); the version is in `manifest.json`.

A package installed with `makepkg` also carries this plugin in `/usr/share/scriptwidget/omarchy-plugin`; linking that folder to `~/.config/omarchy/plugins/com.atomsprout.scriptwidget` instead keeps it in step with the package automatically.

## Source

This repository is a copy of [`Linux/omarchy-plugin`](https://github.com/everettjf/scriptwidget/tree/main/Linux/omarchy-plugin), updated at each Linux release. Development, the protocol, the security notes and the tests are there, and issues go to the [main repository](https://github.com/everettjf/scriptwidget/issues).

## License

Apache License 2.0. See `LICENSE`.
