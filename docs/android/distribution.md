# Android distribution

The Android app is built in two flavors from the same source, with the same application ID (`com.atomsprout.scriptwidget`), version and signing key.

| Flavor | Goes to | Contains | Build |
| --- | --- | --- | --- |
| `play` | Google Play | Firebase Cloud Messaging, for push-triggered refresh | `./gradlew :app:bundlePlayRelease` → `app/build/outputs/bundle/playRelease/app-play-release.aab` |
| `foss` | GitHub Releases, and from there IzzyOnDroid | No Google or other proprietary library; no push-triggered refresh | `./gradlew :app:assembleFossRelease` → `app/build/outputs/apk/foss/release/app-foss-release.apk` |

Everything else is the same code. The only flavor-specific files are `Android/app/src/play` and `Android/app/src/foss` (`PushBackend` and the Firebase service entry). `foss` never reads `Android/firebase.properties`.

Neither flavor contains analytics or crash reporting, and the app has no way to count installs. Download counts come from each channel: Play Console for Google Play, and the per-file download count of a GitHub release (`gh release view <tag> --json assets`).

## Signing

Both flavors are signed with the key in `Android/keystore.properties` (git-ignored). For the GitHub APK this key is permanent: Android installs an update only when it is signed with the same key, and IzzyOnDroid records the key when it adds the app. Its certificate SHA-256 is `ef474602e80cb63c5ef39e39eda81eb6ae9e77d27c8d13c573e2aad4bb6c1c96`.

On Google Play the same key is the upload key. If Play App Signing generates its own app signing key, a Play install and a GitHub install are signed differently and one cannot update the other: the user has to uninstall first, which removes widgets and data.

## A GitHub release

1. Set `versionCode` and `versionName` in `Android/app/build.gradle.kts`, and add `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`.
2. Run the tests ([test notes](testing.md)), then `cd Android && ./gradlew :app:assembleFossRelease`.
3. Check the APK: it is signed with the key above, is not debuggable, contains no `com.google.firebase` or `com.google.android.gms` classes, and is under 30 MB (IzzyOnDroid's usual limit per app).
4. Install it on a device and start it.
5. Commit, push, and create the release on that commit with the tag `android-v<versionName>` and the APK named `scriptwidget-android-<versionName>.apk`. Pass `--latest=false`: the repository's latest release stays with the other products that share it.

The repository also holds releases of the command line tool (`cli-v…`) and tags of the Apple apps (`v…`), so anything that follows Android releases must filter on the `android-v` prefix.

## IzzyOnDroid

[IzzyOnDroid](https://apt.izzysoft.de/fdroid/) is an F-Droid-compatible repository that takes the developer's own APK from GitHub releases. Its [inclusion policy](https://izzyondroid.org/docs/general/AppInclusionPolicy/) asks for a free license, no proprietary components or trackers, a release-signed APK attached to tagged releases, and the description, icon and screenshots in the repository in the fastlane layout. Those are in `fastlane/metadata/android/en-US/`.

Inclusion is requested once, by its owner, with an issue at <https://codeberg.org/IzzyOnDroid/repodata/issues> using the template there. After that, new releases are picked up from GitHub. The request needs:

| Field | Value |
| --- | --- |
| Name | ScriptWidget |
| Source | https://github.com/everettjf/scriptwidget (the Android app is under `Android/`) |
| License | Apache-2.0 |
| APKs | GitHub releases tagged `android-v*`, file `scriptwidget-android-<version>.apk` |
| Package name | `com.atomsprout.scriptwidget` |
| Category | Tools; home screen widgets written in JavaScript and JSX |
| Notes | Needs Android 15 or later. The repository also has `cli-v*` releases without an APK. Permissions: location, calendar and Health Connect reads are each used only by widgets that declare the capability, after the user allows it in the app |

Not checked: whether the build is reproducible from source (IzzyOnDroid shows a badge when it is), and the app on a device without Google services.
