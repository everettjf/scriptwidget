# Android distribution

The Android app is built in two flavors from the same source, with the same application ID (`com.atomsprout.scriptwidget`), version and signing key.

| Flavor | Goes to | Contains | Build |
| --- | --- | --- | --- |
| `play` | Google Play | Firebase Cloud Messaging, for push-triggered refresh | `./gradlew :app:bundlePlayRelease` → `app/build/outputs/bundle/playRelease/app-play-release.aab` |
| `foss` | GitHub Releases | No Google or other proprietary library; no push-triggered refresh | `./gradlew :app:assembleFossRelease` → `app/build/outputs/apk/foss/release/app-foss-release.apk` |

Everything else is the same code. The only flavor-specific files are `Android/app/src/play` and `Android/app/src/foss` (`PushBackend` and the Firebase service entry). `foss` never reads `Android/firebase.properties`.

Neither flavor contains analytics or crash reporting, and the app has no way to count installs. Download counts come from each channel: Play Console for Google Play, and the per-file download count of a GitHub release (`gh release view <tag> --json assets`).

## Signing

Both flavors are signed with the key in `Android/keystore.properties` (git-ignored). For the GitHub APK this key is permanent: Android installs an update only when it is signed with the same key. Its certificate SHA-256 is `ef474602e80cb63c5ef39e39eda81eb6ae9e77d27c8d13c573e2aad4bb6c1c96`.

On Google Play the same key is the upload key. If Play App Signing generates its own app signing key, a Play install and a GitHub install are signed differently and one cannot update the other: the user has to uninstall first, which removes widgets and data.

## A GitHub release

1. Set `versionCode` and `versionName` in `Android/app/build.gradle.kts`, and add `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`.
2. Run the tests ([test notes](testing.md)), then `cd Android && ./gradlew :app:assembleFossRelease`.
3. Check the APK: it is signed with the key above, is not debuggable, contains no `com.google.firebase` or `com.google.android.gms` classes, and is under 30 MB (IzzyOnDroid's usual limit per app).
4. Install it on a device and start it.
5. Commit, push, and create the release on that commit with the tag `android-v<versionName>` and the APK named `scriptwidget-android-<versionName>.apk`. Pass `--latest=false`: the repository's latest release stays with the other products that share it.

The repository also holds releases of the command line tool (`cli-v…`) and tags of the Apple apps (`v…`), so anything that follows Android releases must filter on the `android-v` prefix.

## IzzyOnDroid: not requested

[IzzyOnDroid](https://apt.izzysoft.de/fdroid/) is an F-Droid-compatible repository that takes the developer's own APK from GitHub releases. The `foss` APK and the fastlane metadata meet the technical side of its [inclusion policy](https://izzyondroid.org/docs/general/AppInclusionPolicy/): a free license, no proprietary components or trackers, a release-signed APK on tagged releases, under 30 MB.

No request was filed, because the app does not meet the policy's AI section (read on 14 November 2026):

- Apps whose code was created fully or in part by generative AI tools are rejected. Most of the Android app's code was written with an AI coding assistant, and the request form asks for this to be declared.
- Apps that integrate with LLM services are rejected. The app's optional AI generation calls a model provider with the user's own key.

The request form at <https://codeberg.org/IzzyOnDroid/repodata/issues> also asks its author to confirm that human developers reviewed and manually tested all AI-generated changes. Only the app's owner can state that. Codeberg's own terms now restrict projects written with heavy use of LLMs as well.

F-Droid's main repository builds from source and was not looked into; whether it has a comparable rule is unknown.
