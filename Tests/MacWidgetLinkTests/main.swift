import AppKit
import Foundation

// Isolate the app delegate from iCloud caching for this routing regression test.
final class StubScriptManager {
    func precacheAllScripts() {}
}
let sharedScriptManager = StubScriptManager()

let delegate = AppDelegate()
var openedURLs: [URL] = []
delegate.openWidgetURL = { openedURLs.append($0);return true }

let externalURLs = [
    URL(string: "https://atomsprout.com/scriptwidget")!,
    URL(string: "scriptable:///run/Name")!,
    URL(fileURLWithPath: "/tmp/widget-card.html"),
    URL(string: "mailto:example@example.com")!
]
let internalURLs = [
    kDeepLinkDefaultURL,
    URL(string: "WIDGET-DEEPLINK://default")!,
    URL(string: "scriptwidget://open")!,
    URL(string: "SCRIPTWIDGET://open")!,
    URL(string: "relative/path")!
]

delegate.application(NSApplication.shared, open: internalURLs + externalURLs)
precondition(openedURLs == externalURLs, "Forward external URLs in order and ignore internal/schemeless URLs")
delegate.application(NSApplication.shared, open: [])
precondition(openedURLs == externalURLs, "An empty URL batch should do nothing")

var failedReports=0
delegate.reportUnavailableLink={failedReports+=1}
delegate.openWidgetURL={_ in false}
delegate.application(NSApplication.shared,open:[URL(string:"unknown-launcher-app://open")!])
precondition(failedReports==1,"Unavailable external handlers must report a failure")

print("✓ macOS widget URL routing and failure feedback passed")

MainActor.assumeIsolated {
    var desktopTools: [DesktopToolDestination] = []
    AppDelegate.openDesktopTool = { desktopTools.append($0) }
    let validDesktopURLs = DesktopToolDestination.allCases.map { URL(string: "scriptwidget://desktop-tools/\($0.rawValue)")! }
    let malformedDesktopURLs = [
        "scriptwidget://desktop-tools/launcher?target=file",
        "scriptwidget://desktop-tools/launcher#system",
        "scriptwidget://desktop-tools/launcher/",
        "scriptwidget://desktop-tools/launcher/../music",
        "scriptwidget://desktop-tools/%6cauncher",
        "scriptwidget://desktop-tools/unknown",
        "scriptwidget://desktop-tools/",
        "scriptwidget://name@desktop-tools/music",
        "scriptwidget://desktop-tools:42/music"
    ].compactMap { URL(string: $0) }
    delegate.application(NSApplication.shared, open: malformedDesktopURLs + validDesktopURLs)
    precondition(desktopTools == DesktopToolDestination.allCases, "Only exact internal tool URLs can open the companion")
    precondition(failedReports == 1, "Internal URLs must never reach the external opener")
    precondition(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    AppDelegate.hasFloatingPet = { true }
    precondition(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))

}

let first = DesktopCPUReading(busy: 20, idle: 40)
precondition(DesktopCPUReading(busy: 50, idle: 110).fraction(since: first) == 0.3)
precondition(first.fraction(since: first) == nil)
precondition(DesktopCPUReading(busy: 1, idle: 130).fraction(since: first) == nil)
let earlier = DesktopProcessReading(id: 42, name: "App", startedAt: 10, cpuTicks: 100, residentBytes: 1024)
let current = DesktopProcessReading(id: 42, name: "App", startedAt: 10, cpuTicks: 300, residentBytes: 1024)
let reused = DesktopProcessReading(id: 42, name: "Other", startedAt: 20, cpuTicks: 500, residentBytes: 1024)
precondition(current.cpuPercent(since: earlier, elapsedTicks: 100) == 200)
precondition(current.cpuPercent(since: earlier, elapsedTicks: 0) == nil)
precondition(reused.cpuPercent(since: earlier, elapsedTicks: 100) == nil)
precondition(DesktopSystemSampler.cpu() != nil)
let memory = DesktopSystemSampler.memory()
precondition(memory.map { $0.total > 0 && $0.used > 0 && $0.used <= $0.total } == true)
precondition(DesktopSystemSampler.process(id: getpid(), name: "Runner").map { $0.residentBytes > 0 } == true)

let shortcut = DesktopMediaCommand.shortcutURL(name: "  Play + 音乐&input=clipboard  ")!
let shortcutComponents = URLComponents(url: shortcut, resolvingAgainstBaseURL: false)!
precondition(shortcutComponents.scheme == "shortcuts" && shortcutComponents.host == "run-shortcut")
precondition(shortcutComponents.queryItems == [URLQueryItem(name: "name", value: "Play + 音乐&input=clipboard")])
precondition(shortcut.absoluteString.contains("%2B"))
precondition(DesktopMediaCommand.shortcutURL(name: "bad\u{0000}name") == nil)
precondition(DesktopMediaCommand.shortcutURL(name: String(repeating: "x", count: 201)) == nil)

print("✓ Mac desktop routing, live CPU/memory/process reads, counter edge cases and encoded Shortcuts passed")
