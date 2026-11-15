# Android to-do

What is left before 1.0.0 (version code 1) goes to Google Play. The version was renumbered from 1.2.0 (build 8) on 14 November 2026, because the app starts again under a new developer account and package name; the earlier build numbers in these notes are that development history. Build 7 went to Google Play internal testing on 13 November 2026; that app was then deleted, the package name changed to `com.atomsprout.scriptwidget`, and a new developer account is waiting for identity verification. Tested and untested behavior is in the [test notes](testing.md); the Play Console state is in the [listing kit](../../Android/play/listing.md).

## Not verified yet

| Item | What it needs |
| --- | --- |
| Install the internal test build from Google Play and place a widget | A device signed in to a tester's Google account. The Pixel 6 has no account, and its debug-signed app must be uninstalled first (this removes its widgets) |
| Push while the app is in the background or stopped, with a data-only message | A server that sends through the FCM API. That needs a service account key for the Firebase project `scriptwidget-77792`; creating one needs the owner's approval. Keep the key out of the repository |
| A real registration endpoint receiving the device token | A push server reachable over HTTPS and a test package that declares it |
| `$icloud` sync through a remote cloud provider | A cloud account on two Android devices and a shared folder picked in the app |
| Other vendors' phones (Samsung, Xiaomi and others): launcher sizes, background limits, alarms | The devices, with USB debugging on. Run `Android/scripts/device-test.sh core` and `app` |
| AI generation from the app's own screen with a live model, and OpenAI-compatible or local providers | A key typed into Settings → AI by its owner. The loop itself passed against Anthropic in `AiLiveModelTest` |
| Wallpaper colors after the wallpaper changes | Change the wallpaper or the color theme on a phone with a `material.` widget placed, and check that the widget follows. The colors themselves, in light and dark, were checked on the Pixel 6 |
| The automation entry point from Tasker or MacroDroid | One of those apps installed, with a Send Intent task. It was exercised with `adb shell am broadcast` and from a device test only |
| Scrolling lists on other launchers and on Android 15 and 16 | The emulators and other vendors' phones. Lists were checked on the Pixel 6 (Android 17, Pixel Launcher) only |

## Google Play, once the new developer account is verified

- Follow the submission checklist in the listing kit: create the app as `com.atomsprout.scriptwidget`, add testers, upload 1.0.0 and fill in the store listing and App content again.
- Tablets, other launchers and other vendors' phones have not been checked with the reworked UI (see the [UI review](ui-review.md)).
- Send the first closed testing release for review. Production access needs at least 12 testers opted in to the closed test for at least 14 days.
- Declare trader status for the developer account if Play asks for it.
- Decide whether to keep Play's automatic protection (installer check), which matters if an APK is also distributed.

## Other channels

- GitHub Releases: `android-v1.0.0` is published with the `foss` APK (14 November 2026). Later versions follow [Android distribution](distribution.md).
- IzzyOnDroid: not requested. Its policy rejects apps written with generative AI and apps that integrate with LLM services; see the same page.
- Decide how Play signs the app before the first upload: with its own key, a Play install and a GitHub install cannot update each other.
- The `foss` build has not been run on a device without Google services, and whether it builds reproducibly has not been checked.

## Housekeeping

- Back up the upload key (`~/.scriptwidget-android/scriptwidget-upload.jks`) and `Android/keystore.properties`. Every update must be signed with this key.
- `Android/firebase.properties` is git-ignored; a build without it has push turned off.
- Rotate the Anthropic API key that was used for the live-model test.

## Ideas that only Android can do (not started, new scope)

Scrolling lists, wallpaper colors and the automation entry point are done; see [Only on Android](README.md#only-on-android).


- AI generation and the Studio completions do not know `<list>` and the `material.` colors yet; the reference they use is the iOS one.
- A way for a script to hand data to an action (a row's own identifier), so a list row can do more than toggle a stored value.
- Sending broadcasts from a script to automation apps, after a separate security review.
- Faster refresh with exact alarms or a foreground service, at a battery and permission cost.
- Notification content as a data source, after a separate privacy review.
- Wear OS tiles, and distributing an APK outside Google Play.
