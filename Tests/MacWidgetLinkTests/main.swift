import AppKit
import Foundation

// Isolate the app delegate from iCloud caching for this routing regression test.
final class StubScriptManager {
    func precacheAllScripts() {}
}
let sharedScriptManager = StubScriptManager()

let delegate = AppDelegate()
var openedURLs: [URL] = []
delegate.openWidgetURL = { openedURLs.append($0) }

let externalURLs = [
    URL(string: "https://xnu.app/scriptwidget")!,
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
print("✓ macOS widget URL routing passed")
