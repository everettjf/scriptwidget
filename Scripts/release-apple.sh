#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
IOS_PROJECT="$ROOT/iOS/ScriptWidget.xcodeproj"
MAC_PROJECT="$ROOT/macOS/ScriptWidgetMac.xcodeproj"
IOS_PBXPROJ="$IOS_PROJECT/project.pbxproj"
MAC_PBXPROJ="$MAC_PROJECT/project.pbxproj"
CONFIGURATION=${SCRIPTWIDGET_RELEASE_CONFIGURATION:-Release}
OUTPUT_ROOT=${SCRIPTWIDGET_RELEASE_OUTPUT_DIR:-"$ROOT/__Release/Apple"}
DRY_RUN=0
SKIP_CHECKS=0
ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage: ./Scripts/release-apple.sh [--yes] [--dry-run] [--skip-checks]

Increments the shared patch/build versions, archives iOS and macOS, uploads both
builds to TestFlight, waits for processing, and submits both to App Review.

Required environment variables:
  APPLE_ID
  APPLE_SPECIFIC_PASSWORD
  APPLE_TEAM_ID
  APP_STORE_CONNECT_API_KEY_ID
  APP_STORE_CONNECT_API_ISSUER_ID
  APP_STORE_CONNECT_API_KEY_PATH

Options:
  --yes          Do not ask for confirmation.
  --dry-run      Print the next version/build without changing or uploading.
  --skip-checks  Skip Scripts/release-readiness.sh (not recommended).
  -h, --help     Show this help.
EOF
}

die() { echo "error: $*" >&2; exit 1; }
require_env() {
  eval "value=\${$1:-}"
  [ -n "$value" ] || die "$1 is required"
}
project_value() {
  sed -n "s/^[[:space:]]*$1 = \\([^;]*\\);/\\1/p" "$2" | sort -u
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --skip-checks) SKIP_CHECKS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

[ -f "$IOS_PBXPROJ" ] || die "iOS project not found"
[ -f "$MAC_PBXPROJ" ] || die "macOS project not found"

IOS_VERSION=$(project_value MARKETING_VERSION "$IOS_PBXPROJ")
MAC_VERSION=$(project_value MARKETING_VERSION "$MAC_PBXPROJ")
[ "$(printf '%s\n' "$IOS_VERSION" | wc -l | tr -d ' ')" = 1 ] || die "iOS targets have different versions"
[ "$(printf '%s\n' "$MAC_VERSION" | wc -l | tr -d ' ')" = 1 ] || die "macOS targets have different versions"
[ "$IOS_VERSION" = "$MAC_VERSION" ] || die "iOS ($IOS_VERSION) and macOS ($MAC_VERSION) versions differ"

CURRENT_VERSION=$IOS_VERSION
NEXT_VERSION=$(printf '%s\n' "$CURRENT_VERSION" | awk -F. '
  NF == 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { print $1 "." $2 ".1"; ok=1 }
  NF == 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { print $1 "." $2 "." ($3 + 1); ok=1 }
  END { if (!ok) exit 1 }
') || die "unsupported MARKETING_VERSION: $CURRENT_VERSION"

IOS_BUILD=$(project_value CURRENT_PROJECT_VERSION "$IOS_PBXPROJ" | sort -nu | tail -n 1)
MAC_BUILD=$(project_value CURRENT_PROJECT_VERSION "$MAC_PBXPROJ" | sort -nu | tail -n 1)
[ -n "$IOS_BUILD" ] && [ "$IOS_BUILD" = "$MAC_BUILD" ] || \
  die "iOS ($IOS_BUILD) and macOS ($MAC_BUILD) build numbers differ"
CURRENT_BUILD=$IOS_BUILD
NEXT_BUILD=$((CURRENT_BUILD + 1))

echo "Apple release: $CURRENT_VERSION ($CURRENT_BUILD) -> $NEXT_VERSION ($NEXT_BUILD)"
[ "$DRY_RUN" = 0 ] || exit 0

for name in APPLE_ID APPLE_SPECIFIC_PASSWORD APPLE_TEAM_ID \
  APP_STORE_CONNECT_API_KEY_ID APP_STORE_CONNECT_API_ISSUER_ID APP_STORE_CONNECT_API_KEY_PATH; do
  require_env "$name"
done
[ -f "$APP_STORE_CONNECT_API_KEY_PATH" ] || die "API key not found: $APP_STORE_CONNECT_API_KEY_PATH"
for tool in xcodebuild xcrun ruby perl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

if [ "$ASSUME_YES" = 0 ]; then
  printf 'Upload and submit iOS + macOS %s (%s)? [y/N] ' "$NEXT_VERSION" "$NEXT_BUILD"
  read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) die "cancelled" ;; esac
fi

[ "$SKIP_CHECKS" = 1 ] || "$ROOT/Scripts/release-readiness.sh"

for file in "$IOS_PBXPROJ" "$MAC_PBXPROJ"; do
  perl -pi -e "s/(MARKETING_VERSION = )[^;]+;/\${1}$NEXT_VERSION;/g; s/(CURRENT_PROJECT_VERSION = )[0-9]+;/\${1}$NEXT_BUILD;/g" "$file"
done

RELEASE_DIR="$OUTPUT_ROOT/$NEXT_VERSION-$NEXT_BUILD"
[ ! -e "$RELEASE_DIR" ] || die "release directory already exists: $RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
EXPORT_OPTIONS="$RELEASE_DIR/ExportOptions.plist"
cat >"$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>destination</key><string>export</string>
  <key>method</key><string>app-store-connect</string>
  <key>signingStyle</key><string>automatic</string>
  <key>stripSwiftSymbols</key><true/>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
EOF

archive_export() {
  platform=$1 project=$2 scheme=$3 destination=$4 archive=$5 export_dir=$6
  xcodebuild -project "$project" -scheme "$scheme" -configuration "$CONFIGURATION" \
    -destination "$destination" -archivePath "$archive" -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" archive
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
    -exportOptionsPlist "$EXPORT_OPTIONS" -allowProvisioningUpdates
  echo "✓ Exported $platform"
}

IOS_ARCHIVE="$RELEASE_DIR/ScriptWidget-iOS.xcarchive"
MAC_ARCHIVE="$RELEASE_DIR/ScriptWidget-macOS.xcarchive"
IOS_EXPORT="$RELEASE_DIR/iOS"
MAC_EXPORT="$RELEASE_DIR/macOS"
archive_export iOS "$IOS_PROJECT" ScriptWidget 'generic/platform=iOS' "$IOS_ARCHIVE" "$IOS_EXPORT"
archive_export macOS "$MAC_PROJECT" ScriptWidgetMac 'generic/platform=macOS' "$MAC_ARCHIVE" "$MAC_EXPORT"

IPA=$(find "$IOS_EXPORT" -maxdepth 1 -type f -name '*.ipa' -print | head -n 1)
PKG=$(find "$MAC_EXPORT" -maxdepth 1 -type f -name '*.pkg' -print | head -n 1)
[ -n "$IPA" ] || die "iOS export did not produce an IPA"
[ -n "$PKG" ] || die "macOS export did not produce a PKG"

for spec in "ios:$IPA" "macos:$PKG"; do
  type=${spec%%:*}; file=${spec#*:}
  xcrun altool --validate-app -f "$file" -t "$type" -u "$APPLE_ID" -p '@env:APPLE_SPECIFIC_PASSWORD'
  xcrun altool --upload-app -f "$file" -t "$type" -u "$APPLE_ID" -p '@env:APPLE_SPECIFIC_PASSWORD'
done

ruby "$ROOT/Scripts/app-store-connect-submit.rb" \
  --bundle-id com.everettjf.scriptwidget --version "$NEXT_VERSION" --build "$NEXT_BUILD" \
  --platform IOS --platform MAC_OS

echo "✓ Uploaded iOS and macOS $NEXT_VERSION ($NEXT_BUILD) to TestFlight and App Review"
