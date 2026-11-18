#!/bin/sh
# Installs ScriptWidget for the current user. No root needed.
#
#   sh install.sh [--prefix <folder>] [--no-plugin] [--no-service]
#
# Default prefix: ~/.local  (programs in <prefix>/bin, data in <prefix>/share).
# The background service becomes a systemd user unit; on Omarchy the display
# plugin is copied to ~/.config/omarchy/plugins and enabled.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
prefix="$HOME/.local"
plugin=1
service=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) [ "$#" -ge 2 ] || { echo "--prefix needs a folder" >&2; exit 2; }; prefix=$2; shift 2 ;;
    --no-plugin) plugin=0; shift ;;
    --no-service) service=0; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
case "$prefix" in /*) ;; *) echo "the prefix must be an absolute path" >&2; exit 2 ;; esac
if [ "$(id -u)" -eq 0 ]; then
  echo "run this as your own user, not as root: the service and the widgets belong to a user" >&2
  exit 2
fi

plugin_id=com.atomsprout.scriptwidget
config="${XDG_CONFIG_HOME:-$HOME/.config}"
unit_folder="$config/systemd/user"
plugin_folder="$config/omarchy/plugins/$plugin_id"

# Stop a running copy before its files are replaced.
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user stop scriptwidget.service >/dev/null 2>&1 || true
fi

echo "Installing ScriptWidget into $prefix"
mkdir -p "$prefix/bin" "$prefix/share"
for program in scriptwidget scriptwidget-studio; do
  [ -f "$here/bin/$program" ] || continue
  # Write beside the target and rename, so a running program is never half replaced.
  cp "$here/bin/$program" "$prefix/bin/.$program.new"
  chmod 755 "$prefix/bin/.$program.new"
  mv -f "$prefix/bin/.$program.new" "$prefix/bin/$program"
done
rm -rf "$prefix/share/scriptwidget/runtime" "$prefix/share/scriptwidget/templates"
mkdir -p "$prefix/share/scriptwidget"
cp -R "$here/share/scriptwidget/runtime" "$here/share/scriptwidget/templates" "$prefix/share/scriptwidget/"
for part in applications icons mime; do
  [ -d "$here/share/$part" ] && cp -R "$here/share/$part" "$prefix/share/"
done
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$prefix/share/applications" >/dev/null 2>&1 || true
command -v update-mime-database >/dev/null 2>&1 && update-mime-database "$prefix/share/mime" >/dev/null 2>&1 || true

if [ "$service" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
  mkdir -p "$unit_folder"
  sed "s|^ExecStart=.*|ExecStart=$prefix/bin/scriptwidget host run|" "$here/lib/systemd/user/scriptwidget.service" > "$unit_folder/scriptwidget.service"
  systemctl --user daemon-reload
  if systemctl --user enable --now scriptwidget.service >/dev/null 2>&1; then
    echo "The background service is running (systemctl --user status scriptwidget)."
  else
    echo "The background service could not be started now. Start it from a graphical session with:" >&2
    echo "  systemctl --user enable --now scriptwidget.service" >&2
  fi
else
  echo "The background service was not set up. Start it by hand with: $prefix/bin/scriptwidget host run"
fi

if [ "$plugin" -eq 1 ]; then
  if command -v omarchy >/dev/null 2>&1; then
    rm -rf "$plugin_folder"
    mkdir -p "$plugin_folder"
    cp -R "$here/omarchy-plugin/." "$plugin_folder/"
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
    # The shell needs a moment to find the new folder before it can be enabled.
    enabled=0
    for attempt in 1 2 3 4 5; do
      sleep 1
      if omarchy plugin enable "$plugin_id" >/dev/null 2>&1; then enabled=1; break; fi
    done
    if [ "$enabled" -eq 1 ]; then
      echo "The Omarchy plugin is enabled. If widgets do not appear, run: omarchy restart shell"
    else
      echo "The Omarchy plugin was copied to $plugin_folder. Enable it from a graphical session with:" >&2
      echo "  omarchy plugin enable $plugin_id" >&2
    fi
  else
    echo "Omarchy was not found: the display plugin was not installed, so widgets will not show on the desktop."
    echo "The command line and the management window work without it."
  fi
fi

case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo "Note: $prefix/bin is not on your PATH." ;;
esac
echo "Done. Open ScriptWidget from the launcher, or run: scriptwidget-studio"
