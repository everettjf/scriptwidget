#!/bin/sh
# Writes the PKGBUILD of a release with the checksums of its two archives:
#
#   sh Linux/scripts/pkgbuild.sh <aarch64 .sha256 file> <x86_64 .sha256 file> <output folder>
#
# The output folder gets PKGBUILD and scriptwidget-bin.install, ready to be
# attached to the GitHub release and, later, pushed to the AUR. Run
# `makepkg --printsrcinfo > .SRCINFO` in that folder on an Arch system for the AUR.
set -eu
[ "$#" -eq 3 ] || { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
repository=$(cd "$(dirname "$0")/../.." && pwd)
version=$(sed -n '/^\[workspace.package\]/,/^\[/s/^version = "\(.*\)"/\1/p' "$repository/Linux/Cargo.toml")
sum() {
  value=$(awk '{print $1}' "$1")
  case "$value" in *[!0-9a-f]*|"") echo "not a SHA-256 in $1" >&2; exit 1 ;; esac
  [ "${#value}" -eq 64 ] || { echo "not a SHA-256 in $1" >&2; exit 1; }
  grep -q "linux-$2.tar.gz" "$1" || { echo "$1 is not the $2 archive" >&2; exit 1; }
  echo "$value"
}
aarch64=$(sum "$1" aarch64)
x86_64=$(sum "$2" x86_64)
mkdir -p "$3"
sed -e "s/^pkgver=.*/pkgver=$version/" -e "s/@SHA256_AARCH64@/$aarch64/" -e "s/@SHA256_X86_64@/$x86_64/" \
  "$repository/Linux/packaging/arch/PKGBUILD" > "$3/PKGBUILD"
cp "$repository/Linux/packaging/arch/scriptwidget-bin.install" "$3/"
echo "wrote $3/PKGBUILD for $version"
