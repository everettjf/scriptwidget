//
//  ScriptMetadata.swift
//  ScriptWidget
//
//  Template metadata loaded from meta.json inside a script package.
//

import Foundation
import SwiftUI

struct ScriptMetadata: Codable, Equatable {
    var description: String?
    var category: String?
    var tags: [String]?
    var difficulty: String?
    var icon: String?
    var preview: String?
    var featured: Bool?

    static let empty = ScriptMetadata()
}

// MARK: - Package 2.0 manifest

enum WidgetPackageFamily: String, Codable, CaseIterable, Identifiable {
    case systemSmall
    case systemMedium
    case systemLarge
    case systemExtraLarge
    case systemExtraLargePortrait
    case accessoryCircular
    case accessoryRectangular
    case accessoryInline

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemSmall: "System Small"
        case .systemMedium: "System Medium"
        case .systemLarge: "System Large"
        case .systemExtraLarge: "System Extra Large"
        case .systemExtraLargePortrait: "System Extra Large Portrait"
        case .accessoryCircular: "Accessory Circular"
        case .accessoryRectangular: "Accessory Rectangular"
        case .accessoryInline: "Accessory Inline"
        }
    }
}

enum WidgetPackagePermission: String, Codable, CaseIterable, Identifiable {
    case network
    case location
    case health
    case storage
    case files

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }
}

struct WidgetPackageAuthor: Codable, Equatable {
    var name: String
    var url: String?
}

struct WidgetPackageAction: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var description: String?
    var systemImage: String
    var function: String
}

enum WidgetPackageControlType: String, Codable, CaseIterable {
    case button
    case toggle
}

struct WidgetPackageControl: Codable, Equatable, Identifiable {
    var id: String
    var type: WidgetPackageControlType
    var title: String
    var subtitle: String?
    var systemImage: String
    /// Legacy direct JavaScript function reference. New manifests should use
    /// `actionID` so every system surface resolves the same declared action.
    var action: String?
    var actionID: String? = nil
    var stateKey: String?
}

struct WidgetPackagePushUpdates: Codable, Equatable {
    var registrationURL: String
    var channel: String
}

/// Public, versioned contract for a shareable ScriptWidget project. `meta.json`
/// remains readable for legacy packages, while every newly created/exported
/// package receives this authoritative `widget.json` manifest.
struct WidgetPackageManifest: Codable, Equatable {
    static let currentFormatVersion = 2
    static let defaultRuntimeVersion = "1.0"

    var formatVersion: Int
    var id: String
    var name: String
    var version: String
    var runtimeVersion: String
    var entry: String
    var supportedFamilies: [WidgetPackageFamily]
    var permissions: [WidgetPackagePermission]
    var networkDomains: [String]
    var plugins: [String]?
    var actions: [WidgetPackageAction]?
    var controls: [WidgetPackageControl]?
    var pushUpdates: WidgetPackagePushUpdates?
    var description: String?
    var category: String?
    var tags: [String]?
    var icon: String?
    var preview: String?
    var author: WidgetPackageAuthor?
    var license: String?

    static func newProject(name: String, metadata: ScriptMetadata? = nil) -> WidgetPackageManifest {
        WidgetPackageManifest(
            formatVersion: currentFormatVersion,
            id: "local.\(UUID().uuidString.lowercased())",
            name: name,
            version: "1.0.0",
            runtimeVersion: defaultRuntimeVersion,
            entry: "main.jsx",
            supportedFamilies: [.systemSmall, .systemMedium, .systemLarge],
            permissions: [],
            networkDomains: [],
            plugins: [],
            actions: [],
            controls: [],
            pushUpdates: nil,
            description: metadata?.description,
            category: metadata?.category,
            tags: metadata?.tags,
            icon: metadata?.icon,
            preview: metadata?.preview,
            author: nil,
            license: nil
        )
    }

    static func legacy(name: String, metadata: ScriptMetadata?) -> WidgetPackageManifest {
        var manifest = newProject(name: name, metadata: metadata)
        let slug = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        manifest.id = "legacy.\(slug.isEmpty ? "widget" : slug)"
        return manifest
    }
}

enum WidgetPackageValidationSeverity: String, Codable {
    case warning
    case error
}

struct WidgetPackageValidationIssue: Codable, Equatable, Identifiable {
    let severity: WidgetPackageValidationSeverity
    let code: String
    let message: String

    var id: String { "\(severity.rawValue):\(code):\(message)" }
}

struct WidgetPackageValidationReport: Codable, Equatable {
    var issues: [WidgetPackageValidationIssue]

    var isValid: Bool { !issues.contains { $0.severity == .error } }
    var errors: [WidgetPackageValidationIssue] { issues.filter { $0.severity == .error } }
    var warnings: [WidgetPackageValidationIssue] { issues.filter { $0.severity == .warning } }
}

enum WidgetPackageManifestValidator {
    static func validate(_ manifest: WidgetPackageManifest, package: ScriptWidgetPackage) -> WidgetPackageValidationReport {
        var issues: [WidgetPackageValidationIssue] = []
        func error(_ code: String, _ message: String) {
            issues.append(.init(severity: .error, code: code, message: message))
        }
        func warning(_ code: String, _ message: String) {
            issues.append(.init(severity: .warning, code: code, message: message))
        }

        if manifest.formatVersion != WidgetPackageManifest.currentFormatVersion {
            error("unsupported_format", "Package format \(manifest.formatVersion) is not supported.")
        }
        if manifest.id.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{2,127}$", options: .regularExpression) == nil {
            error("invalid_id", "id must contain 3–128 letters, numbers, dots, or hyphens.")
        }
        let trimmedName = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedName.count > 80 {
            error("invalid_name", "name must contain 1–80 characters.")
        }
        if manifest.version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?$", options: .regularExpression) == nil {
            error("invalid_version", "version must use semantic versioning, for example 1.0.0.")
        }
        if manifest.runtimeVersion != ScriptWidgetBuildContract.runtimeAPIVersion {
            error("unsupported_runtime", "Runtime \(manifest.runtimeVersion) is incompatible with \(ScriptWidgetBuildContract.runtimeAPIVersion).")
        }
        if manifest.entry.hasPrefix("/") || manifest.entry.contains("\\") {
            error("invalid_entry", "entry must be a package-relative POSIX path.")
        } else if let entryURL = package.resolvedPackageURL(relativePath: manifest.entry) {
            if !["js", "jsx"].contains(entryURL.pathExtension.lowercased()) {
                error("invalid_entry_type", "entry must be a .js or .jsx file.")
            } else if !FileManager.default.fileExists(atPath: entryURL.path) {
                error("missing_entry", "Entry file \(manifest.entry) does not exist.")
            }
        } else {
            error("invalid_entry", "entry escapes the package directory.")
        }
        if manifest.supportedFamilies.isEmpty {
            error("missing_families", "At least one supported widget family is required.")
        }
        if Set(manifest.supportedFamilies.map(\.rawValue)).count != manifest.supportedFamilies.count {
            error("duplicate_families", "supportedFamilies must not contain duplicates.")
        }
        if Set(manifest.permissions.map(\.rawValue)).count != manifest.permissions.count {
            error("duplicate_permissions", "permissions must not contain duplicates.")
        }
        if !manifest.networkDomains.isEmpty && !manifest.permissions.contains(.network) {
            error("undeclared_network", "networkDomains requires the network permission.")
        }
        if manifest.permissions.contains(.network) && manifest.networkDomains.isEmpty {
            error("missing_network_domains", "Network access must declare at least one host.")
        }
        if let plugins = manifest.plugins {
            if Set(plugins.map { $0.lowercased() }).count != plugins.count { error("duplicate_plugins", "plugins must contain unique identifiers.") }
            for plugin in plugins where plugin.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{2,127}$", options: .regularExpression) == nil {
                error("invalid_plugin", "Invalid plugin identifier: \(plugin).")
            }
            if !plugins.isEmpty && !manifest.permissions.contains(.network) { error("plugin_network", "Data source plugins require the network permission.") }
        }
        let actions = manifest.actions ?? []
        if actions.count > 16 { error("too_many_actions", "A package may declare at most 16 actions.") }
        if Set(actions.map { $0.id.lowercased() }).count != actions.count {
            error("duplicate_actions", "Action identifiers must be unique.")
        }
        for action in actions {
            if action.id.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,63}$", options: .regularExpression) == nil {
                error("invalid_action_id", "Invalid action identifier: \(action.id).")
            }
            let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty || action.title.count > 40 {
                error("invalid_action_title", "Action titles must contain 1–40 characters.")
            }
            if let description = action.description, description.count > 160 {
                error("invalid_action_description", "Action descriptions may contain at most 160 characters.")
            }
            if action.systemImage.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,79}$", options: .regularExpression) == nil {
                error("invalid_action_image", "Action systemImage must be an SF Symbols name.")
            }
            if action.function.range(of: "^[A-Za-z_$][A-Za-z0-9_$]{0,63}$", options: .regularExpression) == nil {
                error("invalid_action_function", "Action function must be a JavaScript function identifier.")
            }
        }
        if let controls = manifest.controls {
            if controls.count > 8 { error("too_many_controls", "A package may declare at most 8 controls.") }
            if Set(controls.map { $0.id.lowercased() }).count != controls.count {
                error("duplicate_controls", "Control identifiers must be unique.")
            }
            for control in controls {
                if control.id.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,63}$", options: .regularExpression) == nil {
                    error("invalid_control_id", "Invalid control identifier: \(control.id).")
                }
                if control.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || control.title.count > 40 {
                    error("invalid_control_title", "Control titles must contain 1–40 characters.")
                }
                if control.systemImage.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,79}$", options: .regularExpression) == nil {
                    error("invalid_control_image", "Control systemImage must be an SF Symbols name.")
                }
                if control.action != nil && control.actionID != nil {
                    error("ambiguous_control_action", "Controls must declare either action or actionID, not both.")
                } else if let action = control.action {
                    if action.range(of: "^[A-Za-z_$][A-Za-z0-9_$]{0,63}$", options: .regularExpression) == nil {
                        error("invalid_control_action", "Control action must be a JavaScript function identifier.")
                    }
                } else if let actionID = control.actionID {
                    if !actions.contains(where: { $0.id.caseInsensitiveCompare(actionID) == .orderedSame }) {
                        error("missing_control_action", "Control \(control.id) references unknown action \(actionID).")
                    }
                } else {
                    error("missing_control_action", "Controls must declare actionID or the legacy action field.")
                }
                if control.type == .toggle {
                    guard let stateKey = control.stateKey,
                          stateKey.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil else {
                        error("invalid_control_state", "Toggle controls require a valid stateKey.")
                        continue
                    }
                    if !manifest.permissions.contains(.storage) {
                        error("control_storage", "Toggle controls require the storage permission.")
                    }
                } else if control.stateKey != nil {
                    error("button_control_state", "Button controls must not declare stateKey.")
                }
            }
        }
        if let push = manifest.pushUpdates {
            if !manifest.permissions.contains(.network) {
                error("push_network", "pushUpdates requires the network permission.")
            }
            if let url = URL(string: push.registrationURL),
               url.scheme?.lowercased() == "https",
               let host = url.host,
               isPublicHost(host),
               matchesDeclaredHost(host, declarations: manifest.networkDomains) {
                // Validated above.
            } else {
                error("invalid_push_url", "pushUpdates.registrationURL must be a public HTTPS URL on a declared network domain.")
            }
            if push.channel.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) == nil {
                error("invalid_push_channel", "pushUpdates.channel must be a stable 1–128 character identifier.")
            }
        }
        for domain in manifest.networkDomains {
            let normalized = domain.lowercased()
            if domain != normalized
                || normalized.contains("://")
                || normalized.contains("/")
                || normalized.contains(":")
                || normalized.hasPrefix(".")
                || normalized.hasSuffix(".")
                || normalized.range(of: "^[a-z0-9*.-]+$", options: .regularExpression) == nil
                || (normalized.contains("*") && !normalized.hasPrefix("*.")) {
                error("invalid_network_domain", "Invalid network host declaration: \(domain).")
            }
        }
        if let tags = manifest.tags {
            if tags.count > 20 { error("too_many_tags", "A package may declare at most 20 tags.") }
            if Set(tags.map { $0.lowercased() }).count != tags.count {
                warning("duplicate_tags", "Duplicate tags should be removed.")
            }
        }
        if let authorURL = manifest.author?.url,
           URL(string: authorURL)?.scheme?.lowercased() != "https" {
            error("invalid_author_url", "author.url must use HTTPS.")
        }
        if let preview = manifest.preview,
           package.resolvedPackageURL(relativePath: preview) == nil {
            error("invalid_preview", "preview escapes the package directory.")
        }
        return WidgetPackageValidationReport(issues: issues)
    }

    private static func matchesDeclaredHost(_ host: String, declarations: [String]) -> Bool {
        let value = host.lowercased()
        return declarations.contains { declaration in
            if declaration.hasPrefix("*.") {
                let suffix = String(declaration.dropFirst(2))
                return value != suffix && value.hasSuffix("." + suffix)
            }
            return value == declaration
        }
    }

    private static func isPublicHost(_ host: String) -> Bool {
        let value = host.lowercased()
        if value == "localhost" || value == "::1" || value.hasSuffix(".local") ||
            value.hasPrefix("127.") || value.hasPrefix("10.") || value.hasPrefix("192.168.") {
            return false
        }
        let parts = value.split(separator: ".")
        if parts.count == 4, parts.first == "172", let second = Int(parts[1]), (16...31).contains(second) {
            return false
        }
        return true
    }
}

enum ScriptCategory: String, CaseIterable, Identifiable {
    case starter
    case time
    case weather
    case system
    case health
    case finance
    case productivity
    case fun

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .starter:      return "Starter"
        case .time:         return "Time & Date"
        case .weather:      return "Weather"
        case .system:       return "System"
        case .health:       return "Health"
        case .finance:      return "Finance"
        case .productivity: return "Productivity"
        case .fun:          return "Fun"
        }
    }

    var systemImage: String {
        switch self {
        case .starter:      return "square.dashed"
        case .time:         return "clock.fill"
        case .weather:      return "cloud.sun.fill"
        case .system:       return "cpu.fill"
        case .health:       return "heart.fill"
        case .finance:      return "chart.line.uptrend.xyaxis"
        case .productivity: return "checkmark.circle.fill"
        case .fun:          return "gamecontroller.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .starter:      return .gray
        case .time:         return .blue
        case .weather:      return .cyan
        case .system:       return .indigo
        case .health:       return .pink
        case .finance:      return .green
        case .productivity: return .orange
        case .fun:          return .purple
        }
    }
}

enum ScriptDifficulty: String, CaseIterable {
    case beginner
    case medium
    case advanced

    var displayName: String {
        switch self {
        case .beginner: return "Beginner"
        case .medium:   return "Intermediate"
        case .advanced: return "Advanced"
        }
    }
}
