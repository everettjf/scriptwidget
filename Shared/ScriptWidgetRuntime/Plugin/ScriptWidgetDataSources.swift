//
//  ScriptWidgetDataSources.swift
//  ScriptWidget
//
//  Data Source Plugin 1.0 is deliberately declarative. Plugins map validated
//  parameters to HTTPS requests; they cannot load native code or expand a
//  widget's Package 2.0 permissions.
//

import Foundation
import JavaScriptCore
import ZipArchive

enum DataSourceParameterLocation: String, Codable, CaseIterable {
    case path
    case query
    case header
    case jsonBody
}

enum DataSourceResponseType: String, Codable, CaseIterable {
    case json
    case text
}

struct DataSourcePluginParameter: Codable, Equatable, Hashable, Identifiable {
    let id: String
    var label: String
    var location: DataSourceParameterLocation
    var required: Bool
    var defaultValue: String?
}

struct DataSourcePluginOperation: Codable, Equatable, Hashable, Identifiable {
    let id: String
    var title: String
    var method: String
    var path: String
    var responseType: DataSourceResponseType
    var parameters: [DataSourcePluginParameter]
}

struct DataSourcePluginManifest: Codable, Equatable, Hashable, Identifiable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    var id: String
    var name: String
    var version: String
    var summary: String
    var symbol: String
    var author: String
    var license: String
    var minimumRuntimeVersion: String
    var baseURL: URL
    var hosts: [String]
    var operations: [DataSourcePluginOperation]
}

struct DataSourcePluginValidationIssue: Identifiable, Equatable {
    let id: String
    let message: String
}

struct DataSourcePluginValidationReport: Equatable {
    let issues: [DataSourcePluginValidationIssue]
    var isValid: Bool { issues.isEmpty }
}

enum DataSourcePluginValidator {
    static let maximumManifestBytes = 256 * 1_024
    static let maximumOperations = 50
    static let maximumParameters = 30

    static func decode(_ data: Data) -> Result<DataSourcePluginManifest, Error> {
        do {
            guard data.count <= maximumManifestBytes else { throw DataSourcePluginError.invalidManifest("plugin.json exceeds 256 KiB.") }
            try rejectUnknownFields(data)
            let manifest = try JSONDecoder().decode(DataSourcePluginManifest.self, from: data)
            let report = validate(manifest)
            guard report.isValid else { throw DataSourcePluginError.invalidManifest(report.issues.map(\.message).joined(separator: "\n")) }
            return .success(manifest)
        } catch { return .failure(error) }
    }

    static func validate(_ manifest: DataSourcePluginManifest) -> DataSourcePluginValidationReport {
        var issues: [DataSourcePluginValidationIssue] = []
        func reject(_ id: String, _ message: String) { issues.append(.init(id: id, message: message)) }
        if manifest.formatVersion != DataSourcePluginManifest.currentFormatVersion { reject("format", "Unsupported Data Source Plugin format \(manifest.formatVersion).") }
        if !validIdentifier(manifest.id) { reject("id", "Plugin id must be a stable 3–128 character identifier.") }
        if manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manifest.name.count > 80 { reject("name", "Plugin name must contain 1–80 characters.") }
        if !validSemanticVersion(manifest.version) { reject("version", "Plugin version must use semantic versioning.") }
        if manifest.minimumRuntimeVersion != ScriptWidgetBuildContract.runtimeAPIVersion { reject("runtime", "Plugin requires unsupported runtime \(manifest.minimumRuntimeVersion).") }
        guard let scheme = manifest.baseURL.scheme?.lowercased(), scheme == "https",
              let baseHost = manifest.baseURL.host?.lowercased(), manifest.baseURL.user == nil,
              manifest.baseURL.password == nil, manifest.baseURL.query == nil, manifest.baseURL.fragment == nil else {
            reject("base_url", "baseURL must be an HTTPS URL without credentials, query, or fragment.")
            return .init(issues: issues)
        }
        if manifest.hosts.isEmpty || manifest.hosts.count > 20 { reject("hosts", "A plugin must declare 1–20 HTTPS hosts.") }
        if Set(manifest.hosts).count != manifest.hosts.count { reject("hosts", "Plugin hosts must be unique.") }
        for host in manifest.hosts where !ScriptWidgetNetworkPolicy.isValidDomainDeclaration(host) {
            reject("host", "Invalid plugin host declaration: \(host).")
        }
        if !ScriptWidgetNetworkPolicy.host(baseHost, matchesAny: manifest.hosts) { reject("base_host", "baseURL host must be included in hosts.") }
        if manifest.operations.isEmpty || manifest.operations.count > maximumOperations { reject("operations", "A plugin must contain 1–\(maximumOperations) operations.") }
        if Set(manifest.operations.map { $0.id.lowercased() }).count != manifest.operations.count { reject("operation_ids", "Operation ids must be unique.") }
        for operation in manifest.operations {
            let prefix = "operation.\(operation.id)"
            if !validIdentifier(operation.id) { reject(prefix, "Operation id is invalid: \(operation.id).") }
            let method = operation.method.uppercased()
            if operation.method != method || !["GET", "POST", "PUT", "PATCH", "DELETE"].contains(method) { reject(prefix, "Operation \(operation.id) has an unsupported HTTP method.") }
            if operation.path.isEmpty || !operation.path.hasPrefix("/") || operation.path.contains("..") || operation.path.contains("?") || operation.path.contains("#") { reject(prefix, "Operation path must be an absolute URL path without traversal, query, or fragment.") }
            if operation.parameters.count > maximumParameters { reject(prefix, "Operation \(operation.id) has too many parameters.") }
            if Set(operation.parameters.map { $0.id.lowercased() }).count != operation.parameters.count { reject(prefix, "Operation parameter ids must be unique.") }
            let parameterIDs = Set(operation.parameters.map(\.id))
            for parameter in operation.parameters {
                if !validIdentifier(parameter.id) { reject(prefix, "Invalid parameter id: \(parameter.id).") }
                if parameter.location == .path && !operation.path.contains("{\(parameter.id)}") { reject(prefix, "Path parameter \(parameter.id) has no matching placeholder.") }
                if parameter.location != .path && operation.path.contains("{\(parameter.id)}") { reject(prefix, "Placeholder \(parameter.id) must be a path parameter.") }
                if parameter.location == .header && !validHeaderName(parameter.id) { reject(prefix, "Header parameter \(parameter.id) is invalid.") }
            }
            for placeholder in placeholders(in: operation.path) where !parameterIDs.contains(placeholder) {
                reject(prefix, "Path placeholder \(placeholder) has no declared parameter.")
            }
        }
        return .init(issues: issues)
    }

    private static func rejectUnknownFields(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DataSourcePluginError.invalidManifest("plugin.json must be an object.") }
        let rootKeys: Set<String> = ["formatVersion", "id", "name", "version", "summary", "symbol", "author", "license", "minimumRuntimeVersion", "baseURL", "hosts", "operations"]
        let operationKeys: Set<String> = ["id", "title", "method", "path", "responseType", "parameters"]
        let parameterKeys: Set<String> = ["id", "label", "location", "required", "defaultValue"]
        guard Set(root.keys).isSubset(of: rootKeys), let operations = root["operations"] as? [[String: Any]] else { throw DataSourcePluginError.invalidManifest("plugin.json contains unknown fields.") }
        for operation in operations {
            guard Set(operation.keys).isSubset(of: operationKeys), let parameters = operation["parameters"] as? [[String: Any]],
                  parameters.allSatisfy({ Set($0.keys).isSubset(of: parameterKeys) }) else {
                throw DataSourcePluginError.invalidManifest("Plugin operation contains unknown fields.")
            }
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{2,127}$", options: .regularExpression) != nil
    }

    private static func validSemanticVersion(_ value: String) -> Bool {
        value.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?$", options: .regularExpression) != nil
    }

    private static func validHeaderName(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9!#$%&'*+.^_`|~-]+$", options: .regularExpression) != nil
    }

    private static func placeholders(in path: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: "\\{([A-Za-z0-9.-]+)\\}") else { return [] }
        let range = NSRange(path.startIndex..., in: path)
        return expression.matches(in: path, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: path) else { return nil }
            return String(path[valueRange])
        }
    }
}

enum DataSourcePluginError: LocalizedError, Equatable {
    case invalidManifest(String)
    case notFound(String)
    case permission(String)
    case invalidParameters(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let value), .notFound(let value), .permission(let value), .invalidParameters(let value), .network(let value): value
        }
    }
}

struct DataSourcePluginPackage {
    let directory: URL
    var manifestURL: URL { directory.appendingPathComponent("plugin.json") }
    var readmeURL: URL { directory.appendingPathComponent("README.md") }

    func load() -> DataSourcePluginManifest? {
        guard let data = try? Data(contentsOf: manifestURL), case .success(let manifest) = DataSourcePluginValidator.decode(data) else { return nil }
        return manifest
    }

    func save(_ manifest: DataSourcePluginManifest, readme: String = "") -> (Bool, String) {
        let report = DataSourcePluginValidator.validate(manifest)
        guard report.isValid else { return (false, report.issues.map(\.message).joined(separator: "\n")) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
            if !readme.isEmpty { try Data(readme.utf8).write(to: readmeURL, options: .atomic) }
            return (true, "")
        } catch { return (false, error.localizedDescription) }
    }
}

struct DataSourcePluginImportResult: Equatable {
    let succeeded: Bool
    let pluginID: String?
    let message: String
}

final class DataSourcePluginManager {
    static let shared = DataSourcePluginManager()
    static let changedNotification = Notification.Name("DataSourcePluginManagerChanged")
    static let maximumPackageBytes = 512 * 1_024

    let directory: URL

    init(directory: URL? = nil) {
        let scripts = ScriptManager.getICloudPriorityRootDirectory().0
        self.directory = directory ?? scripts.deletingLastPathComponent().appendingPathComponent("Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func allManifests() -> [DataSourcePluginManifest] {
        let custom = packageDirectories().compactMap { DataSourcePluginPackage(directory: $0).load() }
        let customIDs = Set(custom.map(\.id))
        return (Self.builtIns.filter { !customIDs.contains($0.id) } + custom).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func manifest(id: String) -> DataSourcePluginManifest? { allManifests().first { $0.id == id } }
    func package(id: String) -> DataSourcePluginPackage? {
        guard let url = packageDirectories().first(where: { DataSourcePluginPackage(directory: $0).load()?.id == id }) else { return nil }
        return .init(directory: url)
    }

    @discardableResult
    func save(_ manifest: DataSourcePluginManifest, readme: String = "") -> (Bool, String) {
        let package = package(id: manifest.id) ?? DataSourcePluginPackage(directory: uniqueDirectory(name: manifest.name))
        let result = package.save(manifest, readme: readme)
        if result.0 { NotificationCenter.default.post(name: Self.changedNotification, object: self) }
        return result
    }

    @discardableResult
    func delete(id: String) -> (Bool, String) {
        guard let package = package(id: id) else { return (false, "Built-in plugins cannot be deleted.") }
        do {
            try FileManager.default.removeItem(at: package.directory)
            NotificationCenter.default.post(name: Self.changedNotification, object: self)
            return (true, "")
        } catch { return (false, error.localizedDescription) }
    }

    func export(id: String, to archiveURL: URL) -> (Bool, String) {
        let exportPackage: DataSourcePluginPackage
        var temporary: URL?
        if let custom = self.package(id: id) { exportPackage = custom }
        else if let builtIn = Self.builtIns.first(where: { $0.id == id }) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("PluginExport-\(UUID().uuidString)", isDirectory: true)
            temporary = url; exportPackage = .init(directory: url)
            guard exportPackage.save(builtIn, readme: "# \(builtIn.name)\n\n\(builtIn.summary)\n").0 else { return (false, "Could not prepare plugin.") }
        } else { return (false, "Plugin not found.") }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        try? FileManager.default.removeItem(at: archiveURL)
        return SSZipArchive.createZipFile(atPath: archiveURL.path, withContentsOfDirectory: exportPackage.directory.path, keepParentDirectory: false)
            ? (true, "") : (false, "Could not create the .swplugin archive.")
    }

    func importPlugin(from archiveURL: URL) -> DataSourcePluginImportResult {
        guard ((try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max) <= Self.maximumPackageBytes else { return .init(succeeded: false, pluginID: nil, message: "A plugin package may not exceed 512 KiB.") }
        if let message = ScriptPackageArchivePreflight.validate(archiveURL) { return .init(succeeded: false, pluginID: nil, message: message) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("PluginImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        guard SSZipArchive.unzipFile(atPath: archiveURL.path, toDestination: temp.path), let root = importedRoot(in: temp) else { return .init(succeeded: false, pluginID: nil, message: "Archive must contain one Data Source Plugin 1.0 package.") }
        let children = Set(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") })
        guard children.isSubset(of: ["plugin.json", "README.md"]), children.contains("plugin.json"), let manifest = DataSourcePluginPackage(directory: root).load() else { return .init(succeeded: false, pluginID: nil, message: "A plugin package allows only plugin.json and optional README.md.") }
        guard self.manifest(id: manifest.id) == nil else { return .init(succeeded: false, pluginID: nil, message: "Plugin \(manifest.id) is already installed.") }
        do {
            try FileManager.default.copyItem(at: root, to: uniqueDirectory(name: manifest.name))
            NotificationCenter.default.post(name: Self.changedNotification, object: self)
            return .init(succeeded: true, pluginID: manifest.id, message: "")
        } catch { return .init(succeeded: false, pluginID: nil, message: error.localizedDescription) }
    }

    private func packageDirectories() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    private func uniqueDirectory(name: String) -> URL {
        let slug = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = slug.isEmpty ? "plugin" : slug
        var url = directory.appendingPathComponent(base, isDirectory: true), index = 2
        while FileManager.default.fileExists(atPath: url.path) { url = directory.appendingPathComponent("\(base)-\(index)", isDirectory: true); index += 1 }
        return url
    }

    private func importedRoot(in root: URL) -> URL? {
        let children = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []).filter { $0.lastPathComponent != "__MACOSX" }
        if children.contains(where: { $0.lastPathComponent == "plugin.json" }) { return root }
        let directories = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        return directories.count == 1 ? directories[0] : nil
    }

    static let builtIns: [DataSourcePluginManifest] = [
        .init(formatVersion: 1, id: "app.scriptwidget.datasource.open-meteo", name: "Open-Meteo", version: "1.0.0", summary: "Weather forecasts without an API key.", symbol: "cloud.sun", author: "Open-Meteo", license: "CC BY 4.0", minimumRuntimeVersion: "1.0", baseURL: URL(string: "https://api.open-meteo.com")!, hosts: ["api.open-meteo.com"], operations: [
            .init(id: "forecast", title: "Forecast", method: "GET", path: "/v1/forecast", responseType: .json, parameters: [
                .init(id: "latitude", label: "Latitude", location: .query, required: true, defaultValue: "37.7749"),
                .init(id: "longitude", label: "Longitude", location: .query, required: true, defaultValue: "-122.4194"),
                .init(id: "current", label: "Current fields", location: .query, required: false, defaultValue: "temperature_2m,weather_code"),
                .init(id: "timezone", label: "Timezone", location: .query, required: false, defaultValue: "auto")
            ])
        ]),
        .init(formatVersion: 1, id: "app.scriptwidget.datasource.github", name: "GitHub Public API", version: "1.0.0", summary: "Public repository metadata from GitHub.", symbol: "chevron.left.forwardslash.chevron.right", author: "GitHub", license: "API Terms", minimumRuntimeVersion: "1.0", baseURL: URL(string: "https://api.github.com")!, hosts: ["api.github.com"], operations: [
            .init(id: "repository", title: "Repository", method: "GET", path: "/repos/{owner}/{repo}", responseType: .json, parameters: [
                .init(id: "owner", label: "Owner", location: .path, required: true, defaultValue: "everettjf"),
                .init(id: "repo", label: "Repository", location: .path, required: true, defaultValue: "scriptwidget")
            ])
        ])
    ]
}

struct DataSourcePreparedRequest {
    let plugin: DataSourcePluginManifest
    let operation: DataSourcePluginOperation
    let request: URLRequest
}

enum DataSourceRequestBuilder {
    static func prepare(plugin: DataSourcePluginManifest, operationID: String, values: [String: Any]) throws -> DataSourcePreparedRequest {
        guard let operation = plugin.operations.first(where: { $0.id == operationID }) else { throw DataSourcePluginError.notFound("Operation \(operationID) was not found in \(plugin.id).") }
        var path = operation.path
        var query: [URLQueryItem] = []
        var headers: [String: String] = [:]
        var body: [String: Any] = [:]
        let pathAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#{}"))
        for parameter in operation.parameters {
            let raw: Any?
            if let supplied = values[parameter.id] { raw = supplied }
            else { raw = parameter.defaultValue }
            guard let raw, !String(describing: raw).isEmpty else {
                if parameter.required { throw DataSourcePluginError.invalidParameters("Missing required parameter \(parameter.id).") }
                continue
            }
            let string = String(describing: raw)
            switch parameter.location {
            case .path:
                guard let encoded = string.addingPercentEncoding(withAllowedCharacters: pathAllowed) else { throw DataSourcePluginError.invalidParameters("Could not encode \(parameter.id).") }
                path = path.replacingOccurrences(of: "{\(parameter.id)}", with: encoded)
            case .query: query.append(.init(name: parameter.id, value: string))
            case .header: headers[parameter.id] = string
            case .jsonBody: body[parameter.id] = raw
            }
        }
        guard !path.contains("{") && !path.contains("}") else { throw DataSourcePluginError.invalidParameters("A path parameter is unresolved.") }
        guard var components = URLComponents(url: plugin.baseURL, resolvingAgainstBaseURL: false) else { throw DataSourcePluginError.invalidManifest("Invalid plugin baseURL.") }
        // Path placeholders are encoded above. Assigning through `path` would
        // encode their percent signs a second time ("%20" -> "%2520").
        components.percentEncodedPath = (components.percentEncodedPath == "/" ? "" : components.percentEncodedPath) + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, let host = url.host?.lowercased(), ScriptWidgetNetworkPolicy.host(host, matchesAny: plugin.hosts) else { throw DataSourcePluginError.permission("Plugin request escaped its declared hosts.") }
        var request = URLRequest(url: url); request.httpMethod = operation.method
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("ScriptWidget-DataSource/1", forHTTPHeaderField: "User-Agent")
        if !body.isEmpty {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return .init(plugin: plugin, operation: operation, request: request)
    }
}

struct DataSourceExecutionResult {
    let request: URLRequest
    let statusCode: Int
    let data: Data
    let duration: TimeInterval
}

enum DataSourcePluginExecutor {
    static func execute(_ prepared: DataSourcePreparedRequest, session: URLSession = .shared) async throws -> DataSourceExecutionResult {
        let start = ContinuousClock.now
        let (data, response) = try await session.data(for: prepared.request)
        guard let http = response as? HTTPURLResponse else { throw DataSourcePluginError.network("Data source returned an invalid response.") }
        guard (200..<300).contains(http.statusCode) else { throw DataSourcePluginError.network("Data source returned HTTP \(http.statusCode).") }
        guard data.count <= ScriptWidgetFetchManager.maximumResponseBytes else { throw DataSourcePluginError.network("Data source response exceeds 2 MiB.") }
        return .init(request: prepared.request, statusCode: http.statusCode, data: data, duration: start.duration(to: .now).timeInterval)
    }
}

@objc protocol ScriptWidgetRuntimeDataSourceExports: JSExport {
    static func request(_ pluginID: String, _ operationID: String, _ parameters: [String: Any]?) -> ScriptWidgetRuntimePromise
}

@objc final class ScriptWidgetRuntimeDataSource: NSObject, ScriptWidgetRuntimeDataSourceExports {
    static func request(_ pluginID: String, _ operationID: String, _ parameters: [String: Any]?) -> ScriptWidgetRuntimePromise {
        ScriptWidgetRuntimePromise { resolve, reject in
            guard let state = JSContext.current()?.scriptWidgetRunningState, state.executionSession.isActive else { reject.call(withArguments: ["Execution session is no longer active"]); return }
            guard let widgetManifest = state.package.readManifest(), widgetManifest.plugins?.contains(pluginID) == true else { reject.call(withArguments: ["Plugin \(pluginID) is not declared in widget.json"]); return }
            guard widgetManifest.permissions.contains(.network) else { reject.call(withArguments: ["Plugin requests require the network permission"]); return }
            guard let plugin = DataSourcePluginManager.shared.manifest(id: pluginID) else { reject.call(withArguments: ["Plugin \(pluginID) is not installed"]); return }
            do {
                let prepared = try DataSourceRequestBuilder.prepare(plugin: plugin, operationID: operationID, values: parameters ?? [:])
                guard let host = prepared.request.url?.host?.lowercased(), ScriptWidgetNetworkPolicy.host(host, matchesAny: widgetManifest.networkDomains) else { throw DataSourcePluginError.permission("Data source host is not declared in widget.json networkDomains.") }
                var task: URLSessionDataTask!
                task = sharedFetchManager.makeTask(request: prepared.request) { data, response, error in
                    state.executionSession.complete(task)
                    guard state.executionSession.isActive else { return }
                    if let error { reject.call(withArguments: [error.localizedDescription]); return }
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else { reject.call(withArguments: ["Data source request failed"]); return }
                    if prepared.operation.responseType == .json {
                        guard let object = try? JSONSerialization.jsonObject(with: data) else { reject.call(withArguments: ["Data source returned invalid JSON"]); return }
                        resolve.call(withArguments: [object])
                    } else if let text = String(data: data, encoding: .utf8) { resolve.call(withArguments: [text]) }
                    else { reject.call(withArguments: ["Data source returned non-UTF-8 text"]) }
                }
                guard state.executionSession.register(task) else { task.cancel(); reject.call(withArguments: ["Network request budget exceeded"]); return }
                task.resume()
            } catch { reject.call(withArguments: [error.localizedDescription]) }
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let value = components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}
