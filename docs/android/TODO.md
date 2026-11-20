# Android to-do

What is left before 1.0.0 (version code 1) is public on Google Play. On 15 November 2026 it was uploaded to the closed testing track and sent to Google for review; the review passed and the closed test is live for testers. The version was renumbered from 1.2.0 (build 8) on 14 November 2026, because the app starts again under a new developer account and package name; the earlier build numbers in these notes are that development history. Build 7 went to Google Play internal testing on 13 November 2026; that app was then deleted, the package name changed to `com.atomsprout.scriptwidget`, and the app was created again under the new, verified developer account on 15 November 2026. Tested and untested behavior is in the [test notes](testing.md); the Play Console state is in the [listing kit](../../Android/play/listing.md).

## Not verified yet

| Item | What it needs |
| --- | --- |
| Install the internal test build from Google Play and place a widget | A device signed in to a tester's Google account. The Pixel 6 has no account, and its debug-signed app must be uninstalled first (this removes its widgets) |
| Push while the app is in the background or stopped, with a data-only message | A server that sends through the FCM API. That needs a service account key for the Firebase project `scriptwidget-77792`; creating one needs the owner's approval. Keep the key out of the repository |
| A real registration endpoint receiving the device token | A push server reachable over HTTPS and a test package that declares it |
| `$icloud` sync through a remote cloud provider | A cloud account on two Android devices and a shared folder picked in the app |
| Other vendors' phones (Samsung, Xiaomi and others): launcher sizes, background limits, alarms | The devices, with USB debugging on. Run `Android/scripts/device-test.sh core` and `app` |
| The AI conversation with a live model, and OpenAI-compatible or local providers | A key typed into Settings → AI by its owner. The screen passed on the Pixel 6 with a scripted model (`AiConversationUiTest`); the loop itself passed against Anthropic in `AiLiveModelTest` |
| Wallpaper colors after the wallpaper changes | Change the wallpaper or the color theme on a phone with a `material.` widget placed, and check that the widget follows. The colors themselves, in light and dark, were checked on the Pixel 6 |
| The automation entry point from Tasker or MacroDroid | One of those apps installed, with a Send Intent task. It was exercised with `adb shell am broadcast` and from a device test only |
| Scrolling lists on other launchers and on Android 15 and 16 | The emulators and other vendors' phones. Lists were checked on the Pixel 6 (Android 17, Pixel Launcher) only |

## Google Play

- The first closed testing release (1.0.0, sent 15 November 2026) passed review and is live. Recruit testers: each one joins the Google Group `atomsprout@googlegroups.com` (<https://groups.google.com/g/atomsprout>), then opts in at <https://play.google.com/apps/testing/com.atomsprout.scriptwidget>. No tester had opted in when last checked.
- Production access needs at least 12 testers opted in to the closed test for 14 days in a row. Then apply for production in Play Console.
- Install from Play on a device signed in to a tester's account and place a widget. Not done yet.
- Tablets, other launchers and other vendors' phones have not been checked with the reworked UI (see the [UI review](ui-review.md)).
- Declare trader status for the developer account if Play asks for it.
- Decide whether to keep Play's automatic protection (installer check). It is on, the default; it matters because an APK is also distributed on GitHub.

## Other channels

- GitHub Releases: `android-v1.0.0` is published with the `foss` APK (14 November 2026). Later versions follow [Android distribution](distribution.md).
- IzzyOnDroid: not requested. Its policy rejects apps written with generative AI and apps that integrate with LLM services; see the same page.
- Samsung Galaxy Store and other stores: put off (decided 15 November 2026) until the app is on Google Play and has users there. Until then the GitHub APK is the only channel besides Play. Read a store's policy before registering for it.
- Play signing is done: Play signs with the existing key (set on 15 November 2026 with "Export and upload a key from Java keystore"), so a Play install and a GitHub install have the same signature. Updating one from the other has not been tried on a device.
- The `foss` build has not been run on a device without Google services, and whether it builds reproducibly has not been checked.

## Housekeeping

- Back up the upload key (`~/.scriptwidget-android/scriptwidget-upload.jks`) and `Android/keystore.properties`. Every update must be signed with this key.
- `Android/firebase.properties` is git-ignored; a build without it has push turned off.
- Rotate the Anthropic API key that was used for the live-model test.

## Ideas that only Android can do (not started, new scope)

Scrolling lists, wallpaper colors and the automation entry point are done; see [Only on Android](README.md#only-on-android).


- The Studio completions do not know `<list>` and the `material.` colors yet. The editor is a WebView that loads the same `StudioEditor.bundle` as iOS, and the completions are compiled into it, so this needs a change in `Editor/editorfe` (an optional host-supplied list that only the Android bridge sets) and a rebuild of both bundles. The AI prompt on Android describes both since 19 November 2026 (a section of about 250 tokens; not tried with a live model).
- The AI conversation screen is in English and Simplified Chinese since 19 November 2026. Still English there: the Name/OK/Cancel of the shared name dialog, the example chips and the heavy-conversation notice (they come from `core`), error lines from the runtime or a provider, and the default name "AI Widget". The rest of the app has no Chinese.
- Edit replies, the attribute check, the changed lines, the heavy-conversation notice and streamed replies have not been run with a live model on a device; see `docs/ai-conversation-plan.md`. The stream readers for Anthropic and OpenAI-compatible servers are tested against recorded event shapes only.
- A way for a script to hand data to an action (a row's own identifier), so a list row can do more than toggle a stored value.
- Sending broadcasts from a script to automation apps, after a separate security review.
- Faster refresh with exact alarms or a foreground service, at a battery and permission cost.
- Notification content as a data source, after a separate privacy review.
- Wear OS tiles, and distributing an APK outside Google Play.

## Found while testing Windows

- **Bundled templates without `widget.json` that use the network: fixed on 19 November 2026, not committed yet.** A copy of such a template (Daily Quote, Currency Pulse, Weather and six more) failed with "Network host is not declared in widget.json"; this was reproduced on the Pixel 6. As on Windows, the copy now gets a manifest that declares `network` and exactly the hosts named in its own script files (no wildcard, no `localhost`, no IP address; a template that names no host gets no permission). Like Windows, it also declares hosts that are only link targets, so the `link` example gets `www.baidu.com`, `www.bing.com`, `www.google.com` and `atomsprout.com`.
