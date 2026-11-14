# Google Play listing kit (ScriptWidget 1.2.0)

Everything needed to create the Play Console entry and an internal test release.

## Status (13 November 2026)

- There is no app in Play Console at the moment. The first one (`com.everettjf.scriptwidget`, under the AtomSprout developer account, with internal releases 1.2.0 (6) and (7)) was deleted by the owner.
- A new developer account has been created; Google is verifying the owner's identity, which can take a few days. Nothing can be uploaded until then.
- The package name is now `com.atomsprout.scriptwidget`. Only the application ID changed; the Kotlin namespace is still `com.everettjf.scriptwidget`.
- Everything below has to be entered again in the new account: the app, testers, the store listing, the App content declarations and a release. The answers used the first time are kept in "Answers used in the first Play Console setup".
- Firebase: project `scriptwidget-77792`, owned by the `atomsprout@gmail.com` Google account, has the Android app `com.atomsprout.scriptwidget`. Gemini and Analytics are off. `Android/firebase.properties` (git-ignored) holds its values. A test message sent from the Firebase console to the Pixel 6's token was received by the app on 13 November 2026. The first project (`scriptwidget-8ac0e`, under another account) is no longer used.
- Build 8 (version code 8) is the build to upload: `Android/app/build/outputs/bundle/release/app-release.aab`, signed with the upload key. It has the new package name, the iOS icon and the reworked UI.
- The upload key is outside the repository; `Android/keystore.properties` (git-ignored) points to it. It can be reused for the new app. Keep a backup of both: every update must be signed with this key.

## Answers used in the first Play Console setup

- Testers: an email list "ScriptWidget internal" with `evilret@gmail.com` and `atomsprout@googlegroups.com`. Internal testing matches individual Google accounts, so members of the group may need their own addresses listed.
- Privacy policy `https://atomsprout.com/scriptwidget/privacy/`; sign in details: no part of the app is restricted; ads: none; advertising ID: not used; government app: no; financial features: none.
- Target audience: 18 and over.
- Content rating (IARC, "All Other App Types"): the app features online content (Gallery, AI output, widgets' network content); every other answer is No. Rating: Everyone / All ages. Contact for ratings: `atomsprout@gmail.com`.
- Data safety: collects "Device or other IDs" (the Firebase Cloud Messaging token) for app functionality, required, not ephemeral, encrypted in transit, not shared. No account creation. The data deletion question was left unanswered (optional).
- Health apps: features "Activity and fitness", "Nutrition and weight management", "Sleep management", with a written use for each of the nine Health Connect permissions.
- Category Tools; store contact `atomsprout@gmail.com`, website `https://atomsprout.com/scriptwidget/`.
- Store listing with the app icon and feature graphic labelled as created with AI. The screenshots are device captures and are not labelled.
- Play sends the listing and declarations for review with the first closed testing release. Production access needs a closed test with at least 12 opted-in testers for at least 14 days.

## App

| Field | Value |
| --- | --- |
| App name | ScriptWidget |
| Package name | `com.atomsprout.scriptwidget` (cannot change after upload) |
| Default language | English (United States) |
| App or game | App |
| Free or paid | Free |
| Category | Tools |
| Version | 1.2.0 (version code 8) |
| Minimum Android | 15 (API 35) |
| Target API | 36 |
| Contains ads | No |
| In-app purchases | None |
| Website | https://atomsprout.com/scriptwidget/ |
| Privacy policy | https://atomsprout.com/scriptwidget/privacy/ (see "Before production" below) |

## Store listing text

**Short description** (80 characters maximum):

> Write home screen widgets in JavaScript and JSX. Free, with templates and AI.

**Full description:**

> ScriptWidget lets you build your own home screen widgets with JavaScript and JSX.
>
> Write a few lines, see a live preview, and put the result on your home screen. The same widget package runs on iPhone, iPad, Mac and Android.
>
> WHAT YOU CAN BUILD
> • Clocks, countdowns and timers that tick on the home screen
> • Habit trackers, checklists and counters with buttons you tap right in the widget
> • Weather, calendar, health and photo widgets from data you choose to share
> • Dashboards from any HTTPS API you declare
> • Charts, gauges, rings, gradients, icons and animated GIFs
>
> HOW IT WORKS
> • A code editor with syntax highlighting, completion and a live preview
> • More than 140 templates and examples to start from
> • A Gallery of verified widgets you can install and remix
> • Optional AI generation with your own API key: describe a widget and get a working draft
> • Import and export .swt packages to share widgets between devices
>
> PRIVATE BY DESIGN
> • Widgets run on your device in a sandbox with a time and memory limit
> • A widget can only reach the network hosts its package declares
> • Location, calendars, photos, contacts and health data are shared only after you allow it in the app, and only with widgets that declare the capability
> • No account, no ads, no tracking
>
> ScriptWidget is free and open source.

**Release notes for the internal test:**

> First Android build for testing. Small, medium, large and extra-large widgets, the editor, templates with previews, Gallery, AI generation with your own key, Quick Settings tiles, app shortcuts and Live Updates. Tested on a Pixel 6 with Android 17: please report the device and launcher with any problem.

## Graphics in this folder

| File | Use |
| --- | --- |
| `icon-512.png` | App icon, 512 × 512: the iOS app icon, resized |
| `feature-graphic-1024x500.png` | Feature graphic: the icon artwork with the name, drawn by a script |
| `screenshots/01-library.png` … `05-gallery.png` | Phone screenshots, 1080 × 2400, taken on a Pixel 6 from build 8: My Widgets, Templates, a widget's page, the editor, the Gallery |
| `screenshots/06-home-screen.png` | Two widgets on the home screen, 1080 × 1920 (cropped below the status bar) |

The first upload to Play used two wrong pictures (a Google Lens screen in place of the Gallery and the Templates list). All six were retaken.

Play asks whether each graphic was created or edited with AI. The screenshots are device captures. The feature graphic is composed by a script from the icon. Whether the icon artwork itself was made with AI is for its owner to state.

## Submission checklist (once the developer account is verified)

1. Create the app: ScriptWidget, English (United States), App, Free. The package name comes from the bundle.
2. Internal testing: create the testers list, create a release, upload `app-release.aab`, paste the release notes below, roll out.
3. Store listing: name, short and full description from this file; the icon, feature graphic and six screenshots from this folder; answer the AI question as above.
4. Store settings: category Tools; contact email `atomsprout@gmail.com`; website `https://atomsprout.com/scriptwidget/`.
5. App content: enter the answers under "Answers used in the first Play Console setup". Health Connect needs a written use for each of the nine permissions; the texts used the first time said that the `$health` API reads the value so a widget the user created or installed can show it, read-only, on the device, with no server.
6. Install from the opt-in link on a device signed in to a tester account and place a widget.
7. Closed testing: create the track, add at least 12 testers, and send the release for review. Production access opens after 14 days of closed testing.

## Data safety form

The app has no server and sends nothing to the developer.

| Question | Answer |
| --- | --- |
| Does the app collect or share any of the required user data types? | Yes: Device or other IDs (Firebase Cloud Messaging token), collected for app functionality, not shared |
| Is all user data encrypted in transit? | Not applicable (nothing is collected). Requests the user's widgets make use HTTPS or HTTP to hosts the widget declares |
| Can users request data deletion? | Not applicable; everything is stored on the device and removed with the app |

Notes to keep the answers accurate:

- Location, calendar, photos, contacts, documents and health data are read on the device and shown in the user's own widgets. They are not transmitted by the app. A widget the user installs can send data to hosts its package declares; the app shows those hosts and permissions before use.
- AI generation sends the user's prompt and widget source to the provider the user configures, with the user's own API key. That is a user-initiated transfer to a service the user chose.
- If Play's reviewers consider user-configured AI requests or user-installed widgets' network calls as "sharing", revisit this form.

## Permissions and declarations

| Permission | Why |
| --- | --- |
| `INTERNET`, `ACCESS_NETWORK_STATE` | Widgets' declared network requests, Gallery, AI |
| `ACCESS_COARSE_LOCATION`, `ACCESS_FINE_LOCATION` | `$location`, foreground only. No background location |
| `READ_CALENDAR`, `WRITE_CALENDAR` | `$calendar`, limited to calendars the user selects |
| `POST_NOTIFICATIONS`, `POST_PROMOTED_NOTIFICATIONS` | `$notifications`, `$alarms`, Live Updates |
| `RECEIVE_BOOT_COMPLETED` | Re-arm scheduled reminders and redraw widgets after a restart |
| Health Connect read permissions | `$health`. **Requires the Health apps declaration in Play Console** before any track that reviewers check |
| Notification listener service | `$music` reads the active media session after the user enables access |

## Content rating questionnaire

Category "Utility, Productivity, Communication, or Other". No violence, sexual content, profanity, drugs, gambling or user-to-user communication. The app can display content from the Internet through widgets the user writes or installs: answer "Yes" where the questionnaire asks about unrestricted Internet access.

## Internal testing steps (done once; repeat steps 2 and 4 for each new build)

1. Create the app with the values above.
2. Testing → Internal testing → Create new release; upload `app/build/outputs/bundle/release/app-release.aab` built with the upload key.
3. Testers → create an email list containing `evilret@gmail.com`.
4. Roll out and send the opt-in link.

## Before production

- The privacy policy page has an Android section since 13 November 2026 (data on device, Health Connect, Firebase Cloud Messaging token, AI credentials). Keep it in step with the data safety form.
- Complete the Health apps declaration, or remove the Health Connect permissions from the manifest.
- A new personal developer account may need a closed test with a minimum number of testers before production access; check the account's requirements.
