#!/bin/sh
# Builds the release archive of ScriptWidget for Linux:
#
#   Linux/artifacts/scriptwidget-<version>-linux-<arch>.tar.gz  and its .sha256
#
#   sh Linux/scripts/package.sh [--no-studio]
#
# Run on the architecture the archive is for, after
# `node Linux/scripts/build-shared-js.mjs`. Needs the Rust toolchain and the
# development files the build needs (see docs/linux/README.md).
set -eu

studio=1
[ "${1:-}" = "--no-studio" ] && studio=0
repository=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repository/Linux"

version=$(sed -n '/^\[workspace.package\]/,/^\[/s/^version = "\(.*\)"/\1/p' Cargo.toml)
arch=$(uname -m)
name="scriptwidget-$version-linux-$arch"
target="${CARGO_TARGET_DIR:-$repository/Linux/target}"
stage="$repository/Linux/artifacts/$name"

cargo build --locked --release -p sw-cli
[ "$studio" -eq 1 ] && cargo build --locked --release -p sw-studio --features ui

rm -rf "$stage" "$stage.tar.gz" "$stage.tar.gz.sha256"
mkdir -p "$stage/bin" "$stage/share/applications" "$stage/share/mime/packages" "$stage/lib/systemd/user"
cp "$target/release/scriptwidget" "$stage/bin/"
[ "$studio" -eq 1 ] && cp "$target/release/scriptwidget-studio" "$stage/bin/"
strip "$stage"/bin/* 2>/dev/null || true
sh "$repository/Linux/scripts/stage-resources.sh" "$stage/share/scriptwidget"
cp packaging/scriptwidget-studio.desktop "$stage/share/applications/"
cp packaging/scriptwidget-studio.xml "$stage/share/mime/packages/"
cp -R packaging/icons "$stage/share/icons"
cp packaging/systemd/scriptwidget.service "$stage/lib/systemd/user/"
mkdir -p "$stage/omarchy-plugin"
for item in manifest.json Service.qml WidgetWindow.qml ArrangeWindow.qml BarWidget.qml README.md LICENSE i18n; do
  cp -R "omarchy-plugin/$item" "$stage/omarchy-plugin/"
done
cp packaging/release/install.sh packaging/release/uninstall.sh packaging/release/README.txt "$stage/"
cp packaging/release/THIRD-PARTY-NOTICES.txt "$stage/"
cp "$repository/LICENSE" "$stage/"
cp "$repository/Android/core/src/main/assets/fonts/OFL-Inter.txt" "$stage/"
chmod 755 "$stage/install.sh" "$stage/uninstall.sh"
find "$stage" -name '.DS_Store' -delete

# The archive must not carry the six display fonts (see sw-render/src/fonts.rs).
if find "$stage" -iname '*.ttf' -o -iname '*.otf' | grep -q .; then
  echo "font files found in the archive" >&2
  exit 1
fi

cd "$repository/Linux/artifacts"
tar --owner=0 --group=0 --numeric-owner -czf "$name.tar.gz" "$name" 2>/dev/null || tar -czf "$name.tar.gz" "$name"
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$name.tar.gz" > "$name.tar.gz.sha256"; else shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256"; fi
ls -l "$name.tar.gz"
cat "$name.tar.gz.sha256"
