# Google Play listing kit (ScriptWidget 1.2.0)

Everything needed to create the Play Console entry and an internal test release. Nothing here has been submitted.

## App

| Field | Value |
| --- | --- |
| App name | ScriptWidget |
| Package name | `com.everettjf.scriptwidget` (cannot change after upload) |
| Default language | English (United States) |
| App or game | App |
| Free or paid | Free |
| Category | Tools |
| Version | 1.2.0 (version code 3) |
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

> First Android build for internal testing. Small, medium, large and extra-large widgets, the editor, templates, Gallery, AI generation with your own key, Quick Settings tiles, app shortcuts and Live Updates. Tested on a Pixel 6 with Android 17 only: please report the device and launcher with any problem.

## Graphics in this folder

| File | Use |
| --- | --- |
| `icon-512.png` | App icon, 512 × 512 |
| `feature-graphic-1024x500.png` | Feature graphic |
| `screenshots/01-library.png` … `06-home-screen.png` | Phone screenshots, 1080 × 2400, taken on a Pixel 6 |

## Data safety form

The app has no server and sends nothing to the developer.

| Question | Answer |
| --- | --- |
| Does the app collect or share any of the required user data types? | No |
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

## Internal testing steps

1. Create the app with the values above.
2. Testing → Internal testing → Create new release; upload `app/build/outputs/bundle/release/app-release.aab` built with the upload key.
3. Testers → create an email list containing `evilret@gmail.com`.
4. Roll out and send the opt-in link.

## Before production

- The privacy policy page is written for the Apple apps and mentions iCloud. Add an Android section (data on device, Health Connect, user-configured AI provider) before any public track.
- Complete the Health apps declaration, or remove the Health Connect permissions from the manifest.
- A new personal developer account may need a closed test with a minimum number of testers before production access; check the account's requirements.
