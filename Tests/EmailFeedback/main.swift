import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let draft = AtomSproutFeedbackEmail(appName: "反馈 & Mail + Test", version: "1.2+beta", build: "42",
    system: "iOS 27.1", model: "iPhone17,1", language: "zh-Hans", prompt: "50% + details & steps?\n第二行")
let url = draft.mailtoURL!
let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false)!
let items = Dictionary(uniqueKeysWithValues: parsed.queryItems!.map { ($0.name, $0.value ?? "") })
require(parsed.scheme == "mailto", "Feedback must use the user's mail client")
require(parsed.path == "atomsprout@gmail.com", "Wrong support recipient")
require(items["subject"] == draft.subject, "Subject Unicode/query injection round trip")
require(items["body"] == draft.body, "Body Unicode/newlines/percent round trip")
require(parsed.percentEncodedQuery!.contains("%2B"), "Plus signs must not be decoded as spaces")
require(items.count == 2, "Only subject and body query fields may be sent")
for value in ["反馈 & Mail + Test", "1.2+beta (42)", "iOS 27.1", "iPhone17,1", "zh-Hans"] {
    require(draft.body.contains(value), "Missing diagnostic field: \(value)")
}
let metadataLines = draft.body.components(separatedBy: "\n---\n").last!.components(separatedBy: "\n")
let allowedKeys = ["App:", "Version:", "System:", "Device model:", "Language:"]
require(metadataLines.count == allowedKeys.count, "Diagnostics must not gain personal-data fields")
for (line, key) in zip(metadataLines, allowedKeys) { require(line.hasPrefix(key), "Unexpected diagnostic field") }
require(draft.copyableText.contains(AtomSproutFeedbackEmail.recipient), "No-mail fallback must retain recipient")
require(draft.copyableText.contains(draft.subject), "No-mail fallback must retain subject")
require(draft.copyableText.hasSuffix(draft.body), "No-mail fallback must retain the complete message")
let empty = AtomSproutFeedbackEmail(appName: "App", version: "?", build: "?", system: "", model: "", language: "", prompt: "")
require(empty.mailtoURL != nil, "Missing optional system details must not break feedback")
let current = AtomSproutFeedbackEmail.current(appName: "Test App", prompt: "Test")
require(current.appName == "Test App", "Caller must choose the product name")
require(!current.system.isEmpty && !current.model.isEmpty && !current.language.isEmpty, "Basic system information unavailable")
print("Feedback email tests passed: encoding, metadata, privacy allowlist, and complete copy fallback.")
