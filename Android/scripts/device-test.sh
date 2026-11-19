#!/bin/sh
# Runs instrumented tests of a module on the connected device without
# uninstalling the test APK, so files the tests save can be pulled afterwards.
#   scripts/device-test.sh core [ClassName[#method]]   -> prints the result
# The app is tested as its `play` flavor; set FLAVOR=foss for the build without Firebase.
# SUFFIX=.dev tests a copy installed beside the Play Store app, with its own data.
set -e
cd "$(dirname "$0")/.."
module="${1:-core}"
package="com.everettjf.scriptwidget.$module.test"
suffix="${SUFFIX:-}"
application="com.atomsprout.scriptwidget$suffix"
[ "$module" = "app" ] && package="$application.test"
flavor="${FLAVOR:-play}"
variant="$(printf %s "$flavor" | cut -c1 | tr a-z A-Z)$(printf %s "$flavor" | cut -c2-)Debug"
if [ "$module" = "app" ]; then
  ./gradlew -q ${suffix:+-PdevSuffix=$suffix} ":app:install${variant}AndroidTest" ":app:install${variant}" >/dev/null
else
  ./gradlew -q ":$module:installDebugAndroidTest" >/dev/null
fi
# Lets the app's tests bind widgets through their own AppWidgetHost.
[ "$module" = "app" ] && adb shell appwidget grantbind --package "$application" --user 0
class=""
[ -n "$2" ] && class="-e class com.everettjf.scriptwidget.$( [ "$module" = "app" ] && echo "" || echo "$module." )$2"
adb shell am instrument -w $class "$package/androidx.test.runner.AndroidJUnitRunner" | grep -v "^$" | tail -40
