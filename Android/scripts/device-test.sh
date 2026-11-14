#!/bin/sh
# Runs instrumented tests of a module on the connected device without
# uninstalling the test APK, so files the tests save can be pulled afterwards.
#   scripts/device-test.sh core [ClassName[#method]]   -> prints the result
set -e
cd "$(dirname "$0")/.."
module="${1:-core}"
package="com.everettjf.scriptwidget.$module.test"
[ "$module" = "app" ] && package="com.atomsprout.scriptwidget.test"
./gradlew -q ":$module:installDebugAndroidTest" $( [ "$module" = "app" ] && echo ":app:installDebug" ) >/dev/null
# Lets the app's tests bind widgets through their own AppWidgetHost.
[ "$module" = "app" ] && adb shell appwidget grantbind --package com.atomsprout.scriptwidget --user 0
class=""
[ -n "$2" ] && class="-e class com.everettjf.scriptwidget.$( [ "$module" = "app" ] && echo "" || echo "$module." )$2"
adb shell am instrument -w $class "$package/androidx.test.runner.AndroidJUnitRunner" | grep -v "^$" | tail -40
