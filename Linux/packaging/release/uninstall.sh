#!/bin/sh
# Removes what install.sh installed.
#
#   sh uninstall.sh [--prefix <folder>] [--purge]
#
# --purge also deletes your widgets and settings (~/.local/share/scriptwidget
# data folders and the cache). Without it they are kept.
set -eu

prefix="$HOME/.local"
purge=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) [ "$#" -ge 2 ] || { echo "--prefix needs a folder" >&2; exit 2; }; prefix=$2; shift 2 ;;
    --purge) purge=1; shift ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
case "$prefix" in /*) ;; *) echo "the prefix must be an absolute path" >&2; exit 2 ;; esac

plugin_id=com.atomsprout.scriptwidget
config="${XDG_CONFIG_HOME:-$HOME/.config}"

if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin disable "$plugin_id" >/dev/null 2>&1 || true
fi
rm -rf "$config/omarchy/plugins/$plugin_id"
command -v omarchy-shell >/dev/null 2>&1 && omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now scriptwidget.service >/dev/null 2>&1 || true
fi
rm -f "$config/systemd/user/scriptwidget.service"
command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload >/dev/null 2>&1 || true

rm -f "$prefix/bin/scriptwidget" "$prefix/bin/scriptwidget-studio"
rm -rf "$prefix/share/scriptwidget/runtime" "$prefix/share/scriptwidget/templates" "$prefix/share/scriptwidget/fonts"
rm -f "$prefix/share/applications/scriptwidget-studio.desktop" "$prefix/share/mime/packages/scriptwidget-studio.xml"
find "$prefix/share/icons/hicolor" -name 'scriptwidget-studio.png' -exec rm -f {} + 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$prefix/share/applications" >/dev/null 2>&1 || true
command -v update-mime-database >/dev/null 2>&1 && update-mime-database "$prefix/share/mime" >/dev/null 2>&1 || true

data="${SCRIPTWIDGET_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/scriptwidget}"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/scriptwidget"
if [ "$purge" -eq 1 ]; then
  rm -rf "$data" "$cache"
  echo "ScriptWidget and your widgets were removed."
else
  rmdir "$prefix/share/scriptwidget" 2>/dev/null || true
  echo "ScriptWidget was removed. Your widgets and settings are kept in $data (delete with --purge)."
fi
