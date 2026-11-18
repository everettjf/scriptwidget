#!/bin/sh
# Assembles the read-only data directory the Linux programs look for at run
# time (see Linux/crates/sw-core/src/resources.rs):
#
#   <destination>/runtime/      the generated JavaScript (Linux/assets/scriptwidget)
#   <destination>/templates/    the bundled templates, as the Windows build ships them:
#                               Script.bundle without __Build, dot-files and preview.png
#
#   sh Linux/scripts/stage-resources.sh <destination>
#
# A package installs the result as /usr/share/scriptwidget; an unpacked
# release has it as share/scriptwidget next to bin/. For development,
# SCRIPTWIDGET_RESOURCES=<destination> points the programs at it.
# Run `node Linux/scripts/build-shared-js.mjs` first.
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: stage-resources.sh <destination>" >&2
  exit 2
fi
destination=$1
repository=$(cd "$(dirname "$0")/../.." && pwd)
assets="$repository/Linux/assets/scriptwidget"
bundle="$repository/Shared/ScriptWidgetRuntime/Resource/Script.bundle"

if [ ! -f "$assets/kernel.js" ]; then
  echo "$assets/kernel.js is missing: run node Linux/scripts/build-shared-js.mjs" >&2
  exit 1
fi
if [ ! -d "$bundle/template" ]; then
  echo "$bundle is missing" >&2
  exit 1
fi

rm -rf "$destination/runtime" "$destination/templates"
mkdir -p "$destination/runtime" "$destination/templates"
cp "$assets"/*.js "$assets"/contract.json "$destination/runtime/"
for group in template component api; do
  cp -R "$bundle/$group" "$destination/templates/$group"
done
# What is not part of a shipped template.
find "$destination/templates" -depth \( -name '__Build' -o -name '.*' -o -name 'preview.png' \) -exec rm -rf {} +
# Links are never read as package files; none should be shipped either.
find "$destination/templates" -type l -exec rm -f {} +
find "$destination" -type d -exec chmod 755 {} +
find "$destination" -type f -exec chmod 644 {} +

echo "staged $(ls "$destination/runtime" | wc -l | tr -d ' ') runtime files and $(find "$destination/templates" -name main.jsx | wc -l | tr -d ' ') template entries in $destination"
