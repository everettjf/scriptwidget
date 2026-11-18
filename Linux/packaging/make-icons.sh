#!/bin/sh
# Makes the icons of the management window from the shared app icon
# (Resource/AppIcon/ScriptWidget-AppIcon-2026.png), the one the Windows and
# web builds use. The output is checked in; run this again only when the app
# icon changes. Needs ImageMagick (`magick`) or, on a Mac, `sips`.
#
#   sh Linux/packaging/make-icons.sh
#
# A package installs icons/hicolor/<size>/apps/scriptwidget-studio.png under
# /usr/share/icons/hicolor, scriptwidget-studio.desktop under
# /usr/share/applications and scriptwidget-studio.xml under
# /usr/share/mime/packages.
set -eu
repository=$(cd "$(dirname "$0")/../.." && pwd)
source="$repository/Resource/AppIcon/ScriptWidget-AppIcon-2026.png"
for size in 48 128 256; do
  target="$repository/Linux/packaging/icons/hicolor/${size}x${size}/apps"
  mkdir -p "$target"
  if command -v magick >/dev/null 2>&1; then
    magick "$source" -resize "${size}x${size}" "$target/scriptwidget-studio.png"
  else
    sips -s format png -z "$size" "$size" "$source" --out "$target/scriptwidget-studio.png" >/dev/null
  fi
done
