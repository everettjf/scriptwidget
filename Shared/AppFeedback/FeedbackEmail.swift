import Foundation
import Darwin

/// A user-initiated support draft. Only non-unique app and system metadata is included.
/// Never add document names, logs, account details, receipts, network data or unique device identifiers.
struct AtomSproutFeedbackEmail {
    static let recipient = "atomsprout@gmail.com"
    let appName: String
    let version: String
    let build: String
    let system: String
    let model: String
    let language: String
    let prompt: String

    var subject: String { "[\(appName)] Feedback — \(version) (\(build))" }
    var body: String {
        """
        \(prompt)


        ---
        App: \(appName)
        Version: \(version) (\(build))
        System: \(system)
        Device model: \(model)
        Language: \(language)
        """
    }
    var copyableText: String { "To: \(Self.recipient)\nSubject: \(subject)\n\n\(body)" }
    var mailtoURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.recipient
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        // Some clients interpret a literal plus as a form-encoded space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
    static func current(appName: String, prompt: String) -> Self {
        let info = Bundle.main.infoDictionary ?? [:]
        #if os(macOS)
        let platform = "macOS"
        var length = 0
        sysctlbyname("hw.model", nil, &length, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(length, 1))
        let model: String
        if sysctlbyname("hw.model", &bytes, &length, nil, 0) == 0 {
            model = String(cString: bytes)
        } else { model = "Mac" }
        #else
        let platform = "iOS"
        var machine = utsname()
        uname(&machine)
        let model = withUnsafeBytes(of: &machine.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        #endif
        return Self(appName: appName,
                    version: info["CFBundleShortVersionString"] as? String ?? "?",
                    build: info["CFBundleVersion"] as? String ?? "?",
                    system: "\(platform) \(ProcessInfo.processInfo.operatingSystemVersionString)",
                    model: model,
                    language: Locale.preferredLanguages.first ?? Locale.current.identifier,
                    prompt: prompt)
    }
}
