# Android to-do

What is left after 1.2.0 (build 7). It went to Google Play internal testing on 13 November 2026; that app was then deleted, the package name changed to `com.atomsprout.scriptwidget`, and a new developer account is waiting for identity verification. Tested and untested behavior is in the [test notes](testing.md); the Play Console state is in the [listing kit](../../Android/play/listing.md).

## Not verified yet

| Item | What it needs |
| --- | --- |
| Install the internal test build from Google Play and place a widget | A device signed in to a tester's Google account. The Pixel 6 has no account, and its debug-signed app must be uninstalled first (this removes its widgets) |
| Push while the app is in the background or stopped, with a data-only message | A server that sends through the FCM API. That needs a service account key for the Firebase project `scriptwidget-8ac0e`; creating one needs the owner's approval. Keep the key out of the repository |
| A real registration endpoint receiving the device token | A push server reachable over HTTPS and a test package that declares it |
| `$icloud` sync through a remote cloud provider | A cloud account on two Android devices and a shared folder picked in the app |
| Other vendors' phones (Samsung, Xiaomi and others): launcher sizes, background limits, alarms | The devices, with USB debugging on. Run `Android/scripts/device-test.sh core` and `app` |
| AI generation from the app's own screen with a live model, and OpenAI-compatible or local providers | A key typed into Settings → AI by its owner. The loop itself passed against Anthropic in `AiLiveModelTest` |
| `.github/workflows/android.yml` | It has never run on GitHub |

## Google Play, once the new developer account is verified

- Create the app as `com.atomsprout.scriptwidget`, add testers, upload a release and fill in the store listing and App content again. The answers are in the listing kit.
- Register `com.atomsprout.scriptwidget` as an Android app in the Firebase project `scriptwidget-8ac0e`, update `Android/firebase.properties`, and run `PushDeliveryTest` again. Push is untested with the new package name.
- Run the instrumented tests on the Pixel 6 with the new package name. After the rename the JVM tests, the builds and the app suite on the Android 15 emulator were run; the core suite was not.
- Send the first closed testing release for review. Production access needs at least 12 testers opted in to the closed test for at least 14 days.
- Declare trader status for the developer account if Play asks for it.
- Decide whether to keep Play's automatic protection (installer check), which matters if an APK is also distributed.

## Housekeeping

- Back up the upload key (`~/.scriptwidget-android/scriptwidget-upload.jks`) and `Android/keystore.properties`. Every update must be signed with this key.
- `Android/firebase.properties` is git-ignored; a build without it has push turned off.
- Rotate the Anthropic API key that was used for the live-model test.

## Ideas that only Android can do (not started, new scope)

- Scrollable list widgets.
- An automation entry point (a broadcast other apps can send to run a package action), in place of Shortcuts.
- Faster refresh with exact alarms or a foreground service, at a battery and permission cost.
- Notification content as a data source, after a separate privacy review.
- Wear OS tiles, and distributing an APK outside Google Play.
