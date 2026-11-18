//! `$device`, `$system`, `$xml` and the globals Linux does not implement.
//! The device and system snapshots are built from a made-up `/etc`, `/proc`
//! and `/sys`, and once from the machine the test runs on.

mod api_common;

use std::path::{Path, PathBuf};
use std::sync::Arc;

use api_common::*;
use serde_json::{Value, json};
use sw_core::api::system::{self, Screen};
use sw_core::api::{FetchModule, WeatherModule};
use sw_core::plugins::{DataSourceModule, PluginStore};
use sw_core::{ExecutionRequest, NativeModule};

fn write(root: &Path, relative: &str, text: &str) {
    let path = root.join(relative);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

/// A laptop running Omarchy, as its files describe it.
fn laptop() -> PathBuf {
    let root = temporary_directory("system-root");
    write(&root, "etc/os-release", "NAME=\"Arch Linux\"\nPRETTY_NAME=\"Omarchy \\\"Quattro\\\"\"\nID=arch\n# comment\nBUILD_ID=rolling\nANSI_COLOR='38;2;23;147;209'\n\nBROKEN LINE\n");
    write(&root, "proc/sys/kernel/hostname", "framework\n");
    write(&root, "proc/sys/kernel/osrelease", "6.17.7-arch1-1\n");
    write(&root, "proc/uptime", "12345.67 98765.43\n");
    write(&root, "proc/meminfo", "MemTotal:       16303428 kB\nMemFree:         1234567 kB\n");
    write(&root, "sys/class/power_supply/AC/type", "Mains\n");
    write(&root, "sys/class/power_supply/BAT1/type", "Battery\n");
    write(&root, "sys/class/power_supply/BAT1/capacity", "73\n");
    write(&root, "sys/class/power_supply/BAT1/status", "Discharging\n");
    // A wireless mouse reports a battery too; it is not the machine's.
    write(&root, "sys/class/power_supply/hidpp_battery_0/type", "Battery\n");
    write(&root, "sys/class/power_supply/hidpp_battery_0/scope", "Device\n");
    write(&root, "sys/class/power_supply/hidpp_battery_0/capacity", "5\n");
    write(&root, "sys/class/power_supply/hidpp_battery_0/status", "Charging\n");
    write(&root, "sys/firmware/acpi/platform_profile", "low-power\n");
    root
}

#[test]
fn the_device_is_described_by_files_anyone_may_read() {
    let root = laptop();
    let device = Value::Object(system::device_from(&root, Screen { width: 1280.0, height: 800.0, scale: 2.0 }));
    assert_eq!(device.as_object().unwrap().keys().map(String::as_str).collect::<Vec<_>>(), ["screen", "language", "model", "name", "battery", "systemVersion", "totalDiskSpace", "freeDiskSpace"]);
    assert_eq!(device["screen"], json!({ "width": 1280.0, "height": 800.0, "scale": 2.0 }));
    assert_eq!(device["model"], "PC");
    assert_eq!(device["name"], "framework");
    assert_eq!(device["battery"], json!({ "level": 0.73, "state": "unplugged" }));
    // A rolling release has no version: the kernel release stands in.
    assert_eq!(device["systemVersion"], "6.17.7-arch1-1");
    assert_eq!(device["language"].as_str().map(str::len), Some(2));
    let (total, free) = (device["totalDiskSpace"].as_u64().unwrap(), device["freeDiskSpace"].as_u64().unwrap());
    assert!(total > 0 && free <= total, "{total} {free}");

    let battery = |status: &str, capacity: &str| {
        write(&root, "sys/class/power_supply/BAT1/status", status);
        write(&root, "sys/class/power_supply/BAT1/capacity", capacity);
        Value::Object(system::device_from(&root, Screen::default()))["battery"].clone()
    };
    assert_eq!(battery("Charging\n", "40\n"), json!({ "level": 0.4, "state": "charging" }));
    assert_eq!(battery("Full\n", "100\n"), json!({ "level": 1.0, "state": "full" }));
    assert_eq!(battery("Not charging\n", "80\n"), json!({ "level": 0.8, "state": "charging" }));
    assert_eq!(battery("Not charging\n", "100\n"), json!({ "level": 1.0, "state": "full" }));
    assert_eq!(battery("Unknown\n", "55\n"), json!({ "level": 0.55, "state": "unknown" }));
    assert_eq!(battery("Charging\n", "garbage\n"), json!({ "level": -1.0, "state": "charging" }));
    assert_eq!(battery("Charging\n", "250\n"), json!({ "level": -1.0, "state": "charging" }));
    // A desktop: no battery of its own, so level 1 and "full", as on Windows.
    std::fs::remove_dir_all(root.join("sys/class/power_supply/BAT1")).unwrap();
    assert_eq!(Value::Object(system::device_from(&root, Screen::default()))["battery"], json!({ "level": 1.0, "state": "full" }));
    // A release with a version reports it.
    write(&root, "etc/os-release", "NAME=Fedora\nVERSION_ID=43\nPRETTY_NAME=\"Fedora Linux 43 (Workstation Edition)\"\n");
    assert_eq!(Value::Object(system::device_from(&root, Screen::default()))["systemVersion"], "43");
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn the_system_is_described_with_the_fixed_values_of_the_other_desktops() {
    let root = laptop();
    let info = Value::Object(system::system_from(&root));
    assert_eq!(
        info.as_object().unwrap().keys().map(String::as_str).collect::<Vec<_>>(),
        [
            "appInfo", "locale", "preferredLanguages", "timeZone", "is24HourClock", "calendarInfo", "systemUptime", "memory", "thermalState", "lowPowerMode", "brightness", "reduceMotionEnabled", "platform", "hostName",
            "processName", "osVersionString", "processorCount", "activeProcessorCount"
        ]
    );
    assert_eq!(info["appInfo"], json!({ "name": "ScriptWidget", "bundleId": "com.atomsprout.scriptwidget", "version": env!("CARGO_PKG_VERSION"), "build": "0" }));
    assert_eq!(info["platform"], "linux");
    assert_eq!(info["hostName"], "framework");
    assert_eq!(info["processName"], "ScriptWidget");
    assert_eq!(info["osVersionString"], "Omarchy \"Quattro\" (Linux 6.17.7-arch1-1)");
    assert_eq!(info["systemUptime"], 12345.67);
    assert_eq!(info["memory"], json!({ "physical": 16_303_428u64 * 1024 }));
    assert_eq!((&info["thermalState"], &info["brightness"], &info["reduceMotionEnabled"]), (&json!("nominal"), &json!(1.0), &json!(false)));
    assert_eq!(info["lowPowerMode"], true);
    assert!(info["processorCount"].as_u64().unwrap() >= info["activeProcessorCount"].as_u64().unwrap() && info["activeProcessorCount"].as_u64().unwrap() >= 1);
    assert_eq!(info["calendarInfo"]["identifier"], "gregorian");
    assert!((1..=7).contains(&info["calendarInfo"]["firstWeekday"].as_u64().unwrap()));
    assert!([1, 4].contains(&info["calendarInfo"]["minimumDaysInFirstWeek"].as_u64().unwrap()));
    assert!(info["is24HourClock"].is_boolean());
    // The locale is written like on iOS, the languages like BCP 47.
    let locale = info["locale"].as_str().unwrap();
    assert!(!locale.is_empty() && !locale.contains('-') && !locale.contains('.'), "{locale}");
    assert!(info["preferredLanguages"].as_array().is_some_and(|languages| !languages.is_empty() && languages.iter().all(|language| language.as_str().is_some_and(|tag| !tag.contains('_')))));
    // The zone, its offset and the offset's name agree with each other.
    let zone = &info["timeZone"];
    assert!(!zone["identifier"].as_str().unwrap().is_empty());
    let offset = zone["offsetSeconds"].as_i64().unwrap();
    assert!((-14 * 3600..=14 * 3600).contains(&offset));
    let hours = offset.abs() / 3600;
    assert!(zone["abbreviation"].as_str().unwrap().starts_with(&format!("GMT{}{hours}", if offset < 0 { '-' } else { '+' })), "{zone}");

    // Another profile, or none at all, is not low power.
    write(&root, "sys/firmware/acpi/platform_profile", "balanced\n");
    assert_eq!(system::system_from(&root)["lowPowerMode"], false);
    std::fs::remove_file(root.join("sys/firmware/acpi/platform_profile")).unwrap();
    assert_eq!(system::system_from(&root)["lowPowerMode"], false);
    let _ = std::fs::remove_dir_all(root);
}

/// The clock style, the week and the languages follow the locale; ICU answers the first.
#[test]
fn the_locale_decides_the_clock_and_the_week() {
    let root = temporary_directory("system-locale");
    let expected = [("de-DE", true, 2, 4, "de_DE"), ("en-US", false, 1, 1, "en_US"), ("zh-CN", true, 2, 1, "zh_CN"), ("ar-EG", false, 7, 1, "ar_EG"), ("fa-IR", true, 7, 1, "fa_IR")];
    for (tag, twenty_four, first_weekday, minimum_days, locale) in expected {
        sw_core::intl::set_locale_override(Some(tag));
        let info = system::system_from(&root);
        let device = system::device_from(&root, Screen::default());
        sw_core::intl::set_locale_override(None);
        assert_eq!(info["is24HourClock"], twenty_four, "{tag}");
        assert_eq!(info["calendarInfo"], json!({ "identifier": "gregorian", "firstWeekday": first_weekday, "minimumDaysInFirstWeek": minimum_days }), "{tag}");
        assert_eq!(info["locale"], locale);
        assert_eq!(device["language"], tag[..2]);
    }
    let _ = std::fs::remove_dir_all(root);
}

/// Nothing is assumed about the machine: a system without any of the files still answers.
#[test]
fn missing_files_leave_plain_defaults() {
    let root = temporary_directory("system-empty");
    let device = system::device_from(&root, Screen::default());
    assert_eq!(device["screen"], json!({ "width": 1920.0, "height": 1080.0, "scale": 1.0 }));
    assert_eq!(device["battery"], json!({ "level": 1.0, "state": "full" }));
    assert_eq!(device["systemVersion"], "");
    assert!(!device["name"].as_str().unwrap().is_empty());
    let info = system::system_from(&root);
    assert_eq!(info["osVersionString"], "Linux (Linux )");
    assert_eq!((info["systemUptime"].as_f64(), info["memory"]["physical"].as_u64()), (Some(0.0), Some(0)));
    // A file that is too large to be what it claims is not read.
    write(&root, "etc/os-release", &format!("PRETTY_NAME=\"{}\"\n", "x".repeat(70_000)));
    assert_eq!(system::system_from(&root)["osVersionString"], "Linux (Linux )");
    let _ = std::fs::remove_dir_all(root);
}

fn configured(request: &mut ExecutionRequest<'_>) {
    request.device = Some(system::device_info(Screen { width: 800.0, height: 600.0, scale: 1.5 }));
    request.system = Some(system::system_info());
}

#[test]
fn scripts_read_this_machine_through_device_and_system() {
    let script = r#"
        const battery = $device.battery(), zone = $system.timeZone(), screen = $device.screen();
        $render(<text>{JSON.stringify({
          platform: $system.platform(), model: $device.model(), sameName: $device.name() === $system.hostName() && $device.name().length > 0,
          screen: [screen.width, screen.height, screen.scale], battery: typeof battery.level === "number" && ["charging", "unplugged", "full", "unknown"].includes(battery.state),
          disk: $device.totalDiskSpace() >= $device.freeDiskSpace() && $device.totalDiskSpace() > 0, memory: $system.memory().physical > 64 * 1024 * 1024,
          brightness: $system.brightness(), thermal: $system.thermalState(), app: $system.appInfo().bundleId, process: $system.processName(),
          zone: zone.identifier === Intl.DateTimeFormat().resolvedOptions().timeZone, offset: zone.offsetSeconds === -new Date().getTimezoneOffset() * 60,
          uptime: $system.systemUptime() > 0, cores: $system.activeProcessorCount() >= 1, os: $system.osVersionString().includes("(Linux "),
        })}</text>)
    "#;
    let result = run(script, None, Vec::new(), &[], configured);
    assert!(result.error.is_none(), "{:?}", result.error);
    let tree: Value = serde_json::from_str(result.tree.as_deref().unwrap()).unwrap();
    let values: Value = serde_json::from_str(tree["children"][0].as_str().unwrap()).unwrap();
    let mut expected = json!({
        "platform": "linux", "model": "PC", "sameName": true, "screen": [800, 600, 1.5], "battery": true, "disk": true, "memory": true, "brightness": 1, "thermal": "nominal",
        "app": "com.atomsprout.scriptwidget", "process": "ScriptWidget", "zone": true, "offset": true, "uptime": true, "cores": true, "os": true,
    });
    if !cfg!(target_os = "linux") {
        // The quick loop on a Mac has no /proc: these three are read on Linux only.
        for name in ["memory", "uptime", "os"] {
            expected[name] = values[name].clone();
        }
    }
    assert_eq!(values, expected);
}

#[test]
fn scripts_parse_xml_with_the_bounded_parser() {
    let script = r#"
        const feed = $xml.parse('<rss version="2.0"><channel><title>News &amp; more</title><item id="1"/><item id="2"/></channel></rss>');
        const channel = feed.children[0];
        let refused = [];
        for (const source of ['<!DOCTYPE a [<!ENTITY x "y">]><a>&x;</a>', '<a>&undeclared;</a>', '<a>', '<a>' + 'x'.repeat(300000) + '</a>']) {
          try { $xml.parse(source); refused.push("parsed"); } catch (error) { refused.push(String(error.message)); }
        }
        $render(<text>{JSON.stringify([feed.name, feed.attributes.version, channel.children[0].text, channel.children.map(c => c.name + (c.attributes.id ?? "")).join(","), refused])}</text>)
    "#;
    let result = run(script, None, Vec::new(), &[], |_| {});
    assert!(result.error.is_none(), "{:?}", result.error);
    let tree: Value = serde_json::from_str(result.tree.as_deref().unwrap()).unwrap();
    let values: Value = serde_json::from_str(tree["children"][0].as_str().unwrap()).unwrap();
    assert_eq!(
        values,
        json!([
            "rss", "2.0", "News & more", "title,item1,item2",
            ["XML document type and entity declarations are not allowed", "XML entity references are not allowed", "XML element a is not closed", "XML exceeds the 262144-byte limit"]
        ])
    );
}

/// Globals without a module here answer for themselves: not available, and a call says so.
#[test]
fn globals_linux_does_not_implement_are_unavailable_and_say_so() {
    let script = r#"
        const sync = ["$health", "$reminders", "$music", "$photos", "$calendar", "$location"].map(name => globalThis[name].isAvailable());
        const calls = [
          () => $calendar.events({}), () => $reminders.lists(), () => $health.stepCountToday(), () => $photos.items({}), () => $contacts.selected(), () => $documents.list(),
          () => $home.items(), () => $icloud.status(), () => $alarms.pending(), () => $maps.search({}), () => $services.status(), () => $music.current(), () => $notifications.pending(),
          () => $location.current(),
        ];
        const messages = new Array(calls.length);
        let left = calls.length;
        const settle = (index, message) => { messages[index] = message; if (--left === 0) $render(<text>{JSON.stringify({ sync, messages })}</text>); };
        calls.forEach((call, index) => call().then(() => settle(index, "resolved"), error => settle(index, String(error))));
    "#;
    let directory = temporary_directory("unsupported");
    let fetch = Arc::new(FetchModule::with_parts(public_resolver(), FakeTransport::ok()));
    let modules: Vec<Arc<dyn NativeModule>> = vec![
        fetch.clone(),
        Arc::new(DataSourceModule::new(Arc::new(PluginStore::new(directory.join("Plugins"))))),
        Arc::new(WeatherModule::new(Arc::new(sw_core::api::weather::FetchWeatherTransport::new(fetch)), directory.join("weather"), WeatherModule::user_agent("1.0"))),
    ];
    let result = run(script, None, modules.clone(), &[], |_| {});
    assert!(result.error.is_none(), "{:?}", result.error);
    let tree: Value = serde_json::from_str(result.tree.as_deref().unwrap()).unwrap();
    let values: Value = serde_json::from_str(tree["children"][0].as_str().unwrap()).unwrap();
    assert_eq!(values["sync"], json!([false, false, false, false, false, false]));
    let names = ["$calendar", "$reminders", "$health", "$photos", "$contacts", "$documents", "$home", "$icloud", "$alarms", "$maps", "$services", "$music", "$notifications", "$location"];
    let messages = values["messages"].as_array().unwrap_or_else(|| panic!("{values}"));
    assert_eq!(messages.len(), names.len());
    for (name, message) in names.iter().zip(messages) {
        let message = message.as_str().unwrap_or_else(|| panic!("{values}"));
        assert!(message.contains("[unsupported_platform]") && message.contains(name) && message.contains("is not supported on Linux"), "{name}: {message}");
    }

    // The globals that do have a module are not reported as unsupported: they apply their own rules.
    let supported = r#"
        const messages = [null, null];
        let left = 2;
        const settle = (index, message) => { messages[index] = message; if (--left === 0) $render(<text>{JSON.stringify(messages)}</text>); };
        [$weather.forecast({ latitude: 1, longitude: 2 }), $dataSource.request("app.scriptwidget.datasource.github", "repository", {})]
          .forEach((call, index) => call.then(() => settle(index, "resolved"), error => settle(index, String(error))));
    "#;
    let result = run(supported, None, modules, &[], |_| {});
    let tree: Value = serde_json::from_str(result.tree.as_deref().unwrap()).unwrap();
    let messages: Vec<String> = serde_json::from_str(tree["children"][0].as_str().unwrap()).unwrap();
    assert!(messages[0].contains("[permission_denied]"), "{messages:?}");
    assert!(messages[1].contains("is not declared in widget.json"), "{messages:?}");
    assert!(messages.iter().all(|message| !message.contains("unsupported_platform")), "{messages:?}");
    // Without the modules the same two globals are unsupported as well.
    let result = run(supported, None, Vec::new(), &[], |_| {});
    let tree: Value = serde_json::from_str(result.tree.as_deref().unwrap()).unwrap();
    let messages: Vec<String> = serde_json::from_str(tree["children"][0].as_str().unwrap()).unwrap();
    assert!(messages.iter().all(|message| message.contains("[unsupported_platform]")), "{messages:?}");
    let _ = std::fs::remove_dir_all(directory);
}
