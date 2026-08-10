import Foundation
import Network
import Security
import CryptoKit
import UIKit
import Darwin

extension Notification.Name {
    static let webStudioDocumentSaved = Notification.Name("WebStudioDocumentSaved")
}

struct WebStudioLogEntry: Identifiable, Codable {
    let id: UUID
    let date: Date
    let level: String
    let message: String
}

final class WebStudioServer: ObservableObject {
    static let shared = WebStudioServer()

    @Published private(set) var isRunning = false
    @Published private(set) var pairingCode = ""
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var connectedClientCount = 0
    @Published private(set) var previewPackageName: String?
    @Published private(set) var previewRelativePath: String?
    @Published private(set) var previewRevision = 0
    @Published private(set) var lastError: String?
    @Published private(set) var logs = [WebStudioLogEntry]()
    @Published private(set) var connectionHint: String?

    private let queue = DispatchQueue(label: "app.scriptwidget.web-studio", qos: .userInitiated)
    private var listener: NWListener?
    private var sessionToken = ""
    private var hasPairedBrowser = false
    private var lastSessionActivity: Date?
    private var leaseWorkItem: DispatchWorkItem?
    private let maximumRequestBytes = 2 * 1024 * 1024
    private let sessionLease: TimeInterval

    init(sessionLease: TimeInterval = 15) {
        self.sessionLease = sessionLease
    }

    var displayURLs: [String] {
        guard port != 0 else { return [] }
        let addresses = Self.localIPv4Addresses().map { "http://\($0):\(port)" }
        return addresses
    }

    func start() {
        guard listener == nil else { return }
        pairingCode = Self.randomDigits(count: 6)
        sessionToken = Self.randomToken()
        hasPairedBrowser = false
        lastError = nil
        connectionHint = nil
        logs.removeAll()
        log("info", "Starting Web Studio")

        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.service = NWListener.Service(name: "ScriptWidget", type: "_scriptwidget._tcp")
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self.port = listener.port?.rawValue ?? 0
                        self.isRunning = true
                        self.lastError = nil
                        self.connectionHint = nil
                        self.log("info", "Listening on port \(self.port)")
                        if self.displayURLs.isEmpty {
                            self.connectionHint = "No usable Wi-Fi address was found. Connect this device to Wi-Fi or a personal hotspot, then restart Web Studio."
                        }
#if DEBUG
                        NSLog("Web Studio QA ready: %@", self.displayURLs.joined(separator: ", "))
#endif
                    case .waiting(let error):
                        self.lastError = error.localizedDescription
                        self.connectionHint = "Check Local Network access in Settings, then confirm both devices use the same Wi-Fi without a VPN or guest-network isolation."
                        self.log("warning", "Listener waiting: \(error.localizedDescription)")
                    case .failed(let error):
                        self.lastError = error.localizedDescription
                        self.connectionHint = "Check Local Network access in Settings and try starting Web Studio again."
                        self.log("error", "Listener failed: \(error.localizedDescription)")
                        self.stop()
                    case .cancelled:
                        self.isRunning = false
                        self.port = 0
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            lastError = error.localizedDescription
            connectionHint = "Web Studio could not open a local port. Check Local Network access and try again."
            log("error", "Could not create listener: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        leaseWorkItem?.cancel()
        leaseWorkItem = nil
        sessionToken = ""
        hasPairedBrowser = false
        lastSessionActivity = nil
        connectedClientCount = 0
        isRunning = false
        port = 0
        log("info", "Web Studio stopped")
    }

    private func accept(_ connection: NWConnection) {
        log("debug", "Accepted local HTTP connection")
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard buffer.count <= self.maximumRequestBytes else {
                self.log("warning", "Rejected request larger than 2 MiB")
                self.send(.json(status: 413, ["message": "Request is too large"]), on: connection)
                return
            }
            if let request = HTTPRequest.parse(buffer) {
                self.route(request, connection: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, accumulated: buffer)
            }
        }
    }

    private func route(_ request: HTTPRequest, connection: NWConnection) {
        if request.method == "POST", request.path == "/api/v1/pair" {
            guard !hasPairedBrowser else {
                log("warning", "Rejected pairing while another browser owns the session")
                send(.json(status: 409, ["message": "Another browser is already connected"]), on: connection)
                return
            }
            guard let body = request.json, body["code"] as? String == pairingCode else {
                log("warning", "Rejected invalid pairing code")
                send(.json(status: 401, ["message": "Invalid pairing code"]), on: connection)
                return
            }
            hasPairedBrowser = true
            refreshSessionLease()
            DispatchQueue.main.async { self.connectedClientCount = 1 }
            log("info", "Browser paired")
            send(.json(["token": sessionToken]), on: connection)
            return
        }

        if request.path.hasPrefix("/api/") {
            guard request.headers["x-studio-token"] == sessionToken, !sessionToken.isEmpty else {
                log("warning", "Rejected API request without a valid session")
                send(.json(status: 401, ["message": "Pairing required"]), on: connection)
                return
            }
            refreshSessionLease()
            routeAPI(request, connection: connection)
            return
        }

        serveAsset(request.path, connection: connection)
    }

    private func routeAPI(_ request: HTTPRequest, connection: NWConnection) {
        if request.method == "GET", request.path == "/api/v1/session" {
            send(.json([
                "connected": true,
                "leaseSeconds": Int(sessionLease),
                "device": [
                    "name": UIDevice.current.name,
                    "model": UIDevice.current.localizedModel,
                    "system": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
                ],
                "preview": [
                    "state": previewPackageName == nil ? "idle" : "requested",
                    "package": previewPackageName.map { $0 as Any } ?? NSNull(),
                    "path": previewRelativePath.map { $0 as Any } ?? NSNull(),
                    "sequence": previewRevision,
                ],
            ]), on: connection)
            return
        }

        if request.method == "DELETE", request.path == "/api/v1/session" {
            send(.json(["disconnected": true]), on: connection)
            releaseSession(reason: "Browser disconnected")
            return
        }

        if request.method == "GET", request.path == "/api/v1/packages" {
            let packages: [[String: Any]] = sharedScriptManager.listScripts().map { model in
                let manifest = model.package.effectiveManifest()
                let files = model.package.listFiles()
                    .map(\.relativePath)
                    .filter(Self.isEditableTextFile)
                    .sorted()
                return [
                    "id": model.name,
                    "name": manifest.name,
                    "entry": manifest.entry,
                    "files": files,
                ]
            }
            send(.json(["packages": packages]), on: connection)
            return
        }

        if request.path == "/api/v1/document", request.method == "GET" {
            guard let packageName = request.query["package"],
                  let relativePath = request.query["path"],
                  let model = editableModel(named: packageName),
                  Self.isEditableTextFile(relativePath),
                  let content = model.package.readFile(relativePath: relativePath).0 else {
                send(.json(status: 404, ["message": "Document not found"]), on: connection)
                return
            }
            selectPreview(packageName: model.name, relativePath: model.package.effectiveManifest().entry)
            send(.json([
                "content": content,
                "revision": Self.revision(for: content),
                "readOnly": model.package.readonly,
                "packageName": model.name,
            ]), on: connection)
            return
        }

        if request.path == "/api/v1/document", request.method == "PUT" {
            guard let body = request.json,
                  let packageName = body["package"] as? String,
                  let relativePath = body["path"] as? String,
                  let content = body["content"] as? String,
                  let baseRevision = body["baseRevision"] as? String,
                  content.utf8.count <= 1024 * 1024,
                  let model = editableModel(named: packageName),
                  Self.isEditableTextFile(relativePath) else {
                send(.json(status: 400, ["message": "Invalid document request"]), on: connection)
                return
            }
            guard let currentContent = model.package.readFile(relativePath: relativePath).0 else {
                send(.json(status: 404, ["message": "Document not found"]), on: connection)
                return
            }
            let currentRevision = Self.revision(for: currentContent)
            guard baseRevision == currentRevision else {
                log("warning", "Prevented conflicting save for \(model.name)/\(relativePath)")
                send(.json(status: 409, [
                    "message": "This document changed on the device.",
                    "currentContent": currentContent,
                    "currentRevision": currentRevision,
                ]), on: connection)
                return
            }
            let result = relativePath == model.package.effectiveManifest().entry
                ? model.package.writeMainFile(content: content)
                : model.package.writeFile(relativePath: relativePath, content: content)
            guard result.0 else {
                log("error", "Failed to save \(model.name)/\(relativePath): \(result.1)")
                send(.json(status: 400, ["message": result.1]), on: connection)
                return
            }
            selectPreview(packageName: model.name, relativePath: model.package.effectiveManifest().entry)
            NotificationCenter.default.post(
                name: .webStudioDocumentSaved,
                object: nil,
                userInfo: ["package": model.name, "path": relativePath]
            )
            log("info", "Saved \(model.name)/\(relativePath)")
            send(.json([
                "revision": Self.revision(for: content),
                "preview": ["state": "requested", "package": model.name],
            ]), on: connection)
            return
        }

        send(.json(status: 404, ["message": "Unknown Studio API"]), on: connection)
    }

    private func editableModel(named name: String) -> ScriptModel? {
        sharedScriptManager.listScripts().first { $0.name == name && !$0.package.readonly }
    }

    private func selectPreview(packageName: String, relativePath: String) {
        DispatchQueue.main.async {
            self.previewPackageName = packageName
            self.previewRelativePath = relativePath
            self.previewRevision += 1
        }
    }

    private func serveAsset(_ requestPath: String, connection: NWConnection) {
        guard requestPath == "/" || !requestPath.contains(".."),
              let outerBundleURL = Bundle.main.url(forResource: "StudioEditor", withExtension: "bundle"),
              let bundle = Bundle(url: outerBundleURL) else {
            send(.text(status: 404, "Not found"), on: connection)
            return
        }
        let relative = requestPath == "/" ? "index.html" : String(requestPath.dropFirst())
        let url = bundle.resourceURL!.appendingPathComponent(relative).standardizedFileURL
        guard url.path.hasPrefix(bundle.resourceURL!.standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: url) else {
            send(.text(status: 404, "Not found"), on: connection)
            return
        }
        send(HTTPResponse(status: 200, contentType: Self.mimeType(for: url), body: data), on: connection)
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.encoded, completion: .contentProcessed { _ in connection.cancel() })
    }

    var diagnosticReport: String {
        let formatter = ISO8601DateFormatter()
        let header = [
            "ScriptWidget Web Studio diagnostics",
            "Generated: \(formatter.string(from: Date()))",
            "Running: \(isRunning)",
            "Port: \(port)",
            "Addresses: \(displayURLs.joined(separator: ", "))",
            "Connected browsers: \(connectedClientCount)",
            "Last error: \(lastError ?? "none")",
            "",
        ]
        let lines = logs.map { "\(formatter.string(from: $0.date)) [\($0.level.uppercased())] \($0.message)" }
        return (header + lines).joined(separator: "\n")
    }

    private func refreshSessionLease() {
        lastSessionActivity = Date()
        leaseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let activity = self.lastSessionActivity else { return }
            let remaining = self.sessionLease - Date().timeIntervalSince(activity)
            if remaining > 0 {
                self.scheduleLeaseCheck(after: remaining)
            } else {
                self.releaseSession(reason: "Browser heartbeat expired")
            }
        }
        leaseWorkItem = workItem
        queue.asyncAfter(deadline: .now() + sessionLease, execute: workItem)
    }

    private func scheduleLeaseCheck(after interval: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in self?.refreshSessionLeaseIfExpired() }
        leaseWorkItem = workItem
        queue.asyncAfter(deadline: .now() + max(0.1, interval), execute: workItem)
    }

    private func refreshSessionLeaseIfExpired() {
        guard let activity = lastSessionActivity else { return }
        if Date().timeIntervalSince(activity) >= sessionLease {
            releaseSession(reason: "Browser heartbeat expired")
        } else {
            scheduleLeaseCheck(after: sessionLease - Date().timeIntervalSince(activity))
        }
    }

    private func releaseSession(reason: String) {
        leaseWorkItem?.cancel()
        leaseWorkItem = nil
        hasPairedBrowser = false
        lastSessionActivity = nil
        sessionToken = Self.randomToken()
        let nextCode = Self.randomDigits(count: 6)
        DispatchQueue.main.async {
            self.connectedClientCount = 0
            self.pairingCode = nextCode
        }
        log("info", reason)
    }

    private func log(_ level: String, _ message: String) {
        let entry = WebStudioLogEntry(id: UUID(), date: Date(), level: level, message: message)
        DispatchQueue.main.async {
            self.logs.append(entry)
            if self.logs.count > 200 { self.logs.removeFirst(self.logs.count - 200) }
        }
    }

    private static func isEditableTextFile(_ path: String) -> Bool {
        let allowed = Set(["jsx", "js", "json", "css", "md", "txt", "csv", "svg"])
        return allowed.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func revision(for content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }

    private static func randomDigits(count: Int) -> String {
        var value = UInt32.zero
        _ = SecRandomCopyBytes(kSecRandomDefault, MemoryLayout.size(ofValue: value), &value)
        return String(format: "%0*u", count, value % UInt32(pow(10.0, Double(count))))
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    private static func localIPv4Addresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        return sequence(first: first, next: { $0.pointee.ifa_next })
            .compactMap { item -> String? in
                let interfaceName = String(cString: item.pointee.ifa_name)
                let excludedPrefixes = ["awdl", "llw", "pdp_ip", "utun", "ipsec"]
                guard let address = item.pointee.ifa_addr,
                      address.pointee.sa_family == UInt8(AF_INET),
                      (item.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                      (item.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                      (item.pointee.ifa_flags & UInt32(IFF_RUNNING)) != 0,
                      !excludedPrefixes.contains(where: interfaceName.hasPrefix) else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return result == 0 ? String(cString: host) : nil
            }
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    var json: [String: Any]? {
        try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    static func parse(_ data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers = [String: String]()
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
            if pair.count == 2 { headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength >= 0 else { return nil }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let target = String(parts[1])
        let components = URLComponents(string: target)
        var query = [String: String]()
        for item in components?.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value
        }
        return HTTPRequest(
            method: String(parts[0]),
            path: components?.path ?? target,
            query: query,
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }
}

private struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    static func json(status: Int = 200, _ value: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func text(status: Int, _ value: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(value.utf8))
    }

    var encoded: Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 409: "Conflict", 413: "Payload Too Large"][status] ?? "Error"
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        return Data(headers.utf8) + body
    }
}
