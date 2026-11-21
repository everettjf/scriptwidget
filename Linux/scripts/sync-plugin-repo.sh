#!/bin/sh
# Copies the Omarchy plugin into a checkout of its own repository, which
# `omarchy plugin add https://github.com/everettjf/omarchy-scriptwidget.git` installs:
#
#   sh Linux/scripts/sync-plugin-repo.sh <checkout of omarchy-scriptwidget>
#
# Then commit, tag `v<version>` and push in that checkout. Run at each Linux release.
set -eu
[ "$#" -eq 1 ] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
repository=$(cd "$(dirname "$0")/../.." && pwd)
target=$1
[ -d "$target/.git" ] || { echo "$target is not a git checkout" >&2; exit 1; }
plugin="$repository/Linux/omarchy-plugin"
version=$(sed -n '/^\[workspace.package\]/,/^\[/s/^version = "\(.*\)"/\1/p' "$repository/Linux/Cargo.toml")
grep -q "\"version\": \"$version\"" "$plugin/manifest.json" || { echo "manifest.json is not at version $version" >&2; exit 1; }
# Everything at the top of the checkout except .git is replaced.
find "$target" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
for item in manifest.json Service.qml WidgetWindow.qml ArrangeWindow.qml BarWidget.qml LICENSE i18n; do
  cp -R "$plugin/$item" "$target/"
done
cp "$repository/Linux/packaging/omarchy-plugin-repo/README.md" "$target/README.md"
if command -v omarchy >/dev/null 2>&1; then omarchy plugin validate "$target"; fi
echo "copied plugin $version into $target"
