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
