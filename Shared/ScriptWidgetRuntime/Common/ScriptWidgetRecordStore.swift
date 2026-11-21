import Foundation
import CoreFoundation
import Darwin
import ImageIO
import CoreGraphics

enum ScriptWidgetRecordKind: String, CaseIterable, Codable {
    case hydration, mood, checklist, habitStreak, habitHeatmap, countdown, photoCard, weather, healthCard, repoStats, launcher, plantCare, pocketPet, wallpaper

    var title: String {
        switch self {
        case .hydration: return "Water"
        case .mood: return "Mood"
        case .checklist: return "Checklist"
        case .habitStreak: return "Habit"
        case .habitHeatmap: return "Habit Heatmap"
        case .countdown: return "Countdown"
        case .photoCard: return "Photo Card"
        case .wallpaper: return "Wallpaper Match"
        case .plantCare: return "Plant Care"
        case .pocketPet: return "Pocket Pet"
        case .launcher: return "Quick Launcher"
        case .repoStats: return "Repository Stats"
        case .healthCard: return "Health Card"
        case .weather: return "Weather"
        }
    }
    var keys: [String] {
        let records: [String]
        switch self {
        case .countdown, .photoCard, .weather, .healthCard, .repoStats, .launcher, .wallpaper: records = []
        case .plantCare: records = ["plantCare.v1"]
        case .pocketPet: records = ["pocketPet.v1"]
        case .hydration: records = ["hydration.v1"]
        case .mood: records = ["mood.v1"]
        case .checklist: records = ["checklist.v1"]
        case .habitStreak: records = ["habitStreak.v2", "habit.lastDate", "habit.streak"]
        case .habitHeatmap: records = ["habitHeatmap.v1.read", "habitHeatmap.v1.run", "habitHeatmap.v1.meditate"]
        }
        return records + [ScriptWidgetRecordStore.configurationKey]
    }
    var defaults: [String: Any] {
        switch self {
        case .wallpaper: return ["title": "My space", "caption": "", "content": "none", "ink": "adaptive", "backgrounds": [[String:Any]]()]
        case .plantCare: return ["title": "My plant", "intervalDays": 3]
        case .pocketPet: return ["title": "Pebble"]
        case .launcher: return ["title": "Quick Launch", "accent": "blue", "items": ScriptWidgetLauncherItem.defaults.map(\.dictionary)]
        case .repoStats: return ["repository": "everettjf/scriptwidget", "accent": "blue"]
        case .healthCard: return ["metric": "steps", "stepsGoal": 8000, "energyGoal": 500]
        case .weather: return ["city": "", "latitude": 0.0, "longitude": 0.0, "useLocation": true, "unit": "c"]
        case .photoCard: return ["title": "Little moments", "caption": "", "layout": "single", "photos": [String]()]
        case .countdown: return ["title": "Your next moment", "targetDate": "", "repeatYearly": false, "accent": "blue"]
        case .hydration: return ["goal": 8, "glassML": 250]
        case .mood: return ["intention": "Pause, breathe, and notice"]
        case .checklist: return ["items": ["Passport", "Charger", "Headphones"]]
        case .habitStreak: return ["title": "Daily habit"]
        case .habitHeatmap: return ["readName": "Read", "runName": "Run", "meditateName": "Meditate"]
        }
    }

    static func load(package: ScriptWidgetPackage) throws -> Self {
        let primary = package.path.appendingPathComponent("record-template.json")
        var bytes = ScriptWidgetPackageFiles.read(root: package.path, relative: "record-template.json", maximumBytes: 4096)
        if bytes == nil, !package.readonly, !ScriptWidgetMetadataFile.isLink(package.path), !ScriptWidgetMetadataFile.exists(primary),
           !ScriptWidgetMetadataFile.isLink(package.path.appendingPathComponent(".record-template.json.icloud")),
           let cache = ScriptManager.getSandboxBuildDirectoryURL(), ScriptWidgetPackageName.isValid(package.name) {
            bytes = ScriptWidgetPackageFiles.read(root: cache, relative: package.name + "/record-template.json", maximumBytes: 4096)
        }
        guard let bytes,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == ["formatVersion", "kind"], ScriptWidgetRecordStore.integer(object["formatVersion"], range: 1...1),
              let name = object["kind"] as? String, let kind = Self(rawValue: name) else { throw ScriptWidgetRecordError.invalidTemplate }
        return kind
    }
}

enum ScriptWidgetRecordError: LocalizedError, Equatable {
    case invalidTemplate, unavailable, invalidData, invalidBackup, wrongKind, conflict, ambiguousNamespace
    case invalidConfiguration(ScriptWidgetRecordKind)
    var errorDescription: String? {
        switch self {
        case .invalidTemplate: return "This package is not a supported record template, or its storage permission is unavailable."
        case .unavailable: return "Shared record storage is busy or unavailable. Reopen ScriptWidget and try again."
        case .invalidData: return "Some saved records are invalid. Export a backup before replacing them with a valid backup."
        case .invalidConfiguration(let kind):
            switch kind {
            case .wallpaper: return "Choose a title up to 40 characters, caption up to 80, content/ink style, and at most one background per size and appearance (10 total)."
            case .plantCare: return "Enter a plant name of 1–40 characters and a personal care interval of 1–30 days."
            case .pocketPet: return "Enter a pet name of 1–40 characters."
            case .launcher: return "Choose 1–6 links with unique IDs, titles up to 24 characters, valid URLs or shortcut names, and blue/green/rose."
            case .repoStats: return "Enter a public GitHub owner/repository and choose blue, green or rose."
            case .healthCard: return "Choose steps, energy or heart rate, a step goal of 1–100,000 and an energy goal of 1–10,000 kcal."
            case .weather: return "Enter a city label up to 60 characters, latitude −90…90, longitude −180…180, and Celsius or Fahrenheit."
            case .photoCard: return "Choose up to 4 different imported photos, a single/duo/grid layout, a title up to 40 characters and a caption up to 80 characters."
            case .countdown: return "Enter an event name of 1–40 characters and a valid date from 1970–9999. Choose blue, rose or green."
            case .hydration: return "Choose 1–32 glasses and a glass size of 25–2000 mL."
            case .mood: return "Keep the intention to 80 characters."
            case .habitStreak: return "Enter a habit name of 1–40 characters."
            case .habitHeatmap: return "Enter three habit names of 1–40 characters each."
            case .checklist: return "Enter 1–8 unique items, one per line, up to 60 characters each."
            }
        case .invalidBackup: return "This is not a valid record backup, or it exceeds the supported limits."
        case .wrongKind: return "This backup belongs to a different kind of record template."
        case .conflict: return "Records changed after this preview. Reload and review them before trying again."
        case .ambiguousNamespace: return "These widgets have overlapping record locations. Their records need to be migrated safely before editing them here."
        }
    }
}

struct ScriptWidgetRecordSnapshot: Equatable {
    var values: [String: String]
    // Canonical, bounded fingerprints let an explicit restore repair a wrongly
    // typed value without overlooking a concurrent edit. Never executed/imported.
    var unsupported: [String: Data] = [:]
}

struct ScriptWidgetRecordRow: Identifiable, Equatable {
    let id: String
    let date: String
    let label: String
    let value: String
}

struct ScriptWidgetRecordRestore {
    let sourceName: String
    let createdAt: String
    let snapshot: ScriptWidgetRecordSnapshot
    let rows: [ScriptWidgetRecordRow]
}

/// Native UI only. Backup files cannot name a namespace, call JavaScript, or
/// enlarge package permissions. Writes share the widget's cross-process lock.
struct ScriptWidgetRecordStore {
    static let configurationKey = "recordTemplate.config.v1"
    static let maximumBackupBytes = 1024 * 1024
    let package: ScriptWidgetPackage
    let kind: ScriptWidgetRecordKind
    let container: URL
    let defaults: any ScriptWidgetStorageBackend
    private let packageID: String
    private let peers: () -> [String]
    private let executionSnapshot: ScriptWidgetExecutionSnapshot?
    private var namespace: String { executionSnapshot?.storageNamespace ?? "script.\(package.name)." }

    init(package: ScriptWidgetPackage, container: URL, defaults: any ScriptWidgetStorageBackend, peers: @escaping () -> [String] = { [] }) throws {
        self.package = package
        self.container = container
        self.defaults = ScriptWidgetLegacyStorageBackend(defaults, container: container)
        self.peers = peers
        executionSnapshot = nil
        kind = try ScriptWidgetRecordKind.load(package: package)
        guard !package.readonly, ScriptWidgetPackageName.isValid(package.name), let manifest = package.readManifest(),
              WidgetPackageManifestValidator.validate(manifest, package: package, checkEntryExists: false).isValid,
              manifest.permissions.contains(.storage) else { throw ScriptWidgetRecordError.invalidTemplate }
        packageID = manifest.id
        try validateScope()
    }

    /// The snapshot is created by native inventory/binding code, never by a backup.
    /// Its readonly package freezes the descriptor and permission being reviewed;
    /// record writes still target the original UUID and preference backend.
    init(executionSnapshot: ScriptWidgetExecutionSnapshot) throws {
        self.executionSnapshot = executionSnapshot
        package = executionSnapshot.package
        container = executionSnapshot.context.container
        defaults = executionSnapshot.context.defaults
        peers = { [] }
        kind = try ScriptWidgetRecordKind.load(package: package)
        guard let manifest = package.readManifest(), manifest.permissions.contains(.storage),
              WidgetPackageManifestValidator.validate(manifest, package: package, checkEntryExists: false).isValid else {
            throw ScriptWidgetRecordError.invalidTemplate
        }
        packageID = manifest.id
        try validateScope()
    }

    static func live(package: ScriptWidgetPackage) throws -> Self {
        try package.managedScope?.validate(name: package.name)
        if let context = sharedScriptManager.storageContext {
            guard !package.readonly, package.path.standardizedFileURL == context.libraryRoot.appendingPathComponent(package.name) else {
                throw ScriptWidgetRecordError.invalidTemplate
            }
            return try Self(executionSnapshot: ScriptWidgetExecutionSnapshot(name: package.name, role: .source, context: context))
        }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget"),
              let defaults = UserDefaults(suiteName: "group.everettjf.scriptwidget") else { throw ScriptWidgetRecordError.unavailable }
        return try Self(package: package, container: container, defaults: defaults, peers: { ScriptWidgetPackageFiles.list(root: sharedScriptManager.scriptDirectory) ?? [] })
    }

    private func validateScope() throws {
        try executionSnapshot?.validateIdentity()
        guard (executionSnapshot != nil || !package.readonly), let manifest = package.readManifest(), manifest.id == packageID,
              manifest.permissions.contains(.storage), WidgetPackageManifestValidator.validate(manifest, package: package, checkEntryExists: false).isValid,
              try ScriptWidgetRecordKind.load(package: package) == kind else { throw ScriptWidgetRecordError.invalidTemplate }
        // The existing runtime namespace is name-based. Native bulk operations
        // must fail closed on dotted-name overlaps until its migration is done.
        guard executionSnapshot != nil || !peers().contains(where: { $0 != package.name && ($0.hasPrefix(package.name + ".") || package.name.hasPrefix($0 + ".")) }) else {
            throw ScriptWidgetRecordError.ambiguousNamespace
        }
    }

    private func readValues(from store: (any ScriptWidgetStorageBackend)? = nil) throws -> ScriptWidgetRecordSnapshot {
        var result: [String: String] = [:], unsupported: [String: Data] = [:], total = 0
        for key in kind.keys {
            guard let existing = (try (store ?? defaults).readValue(forKey: namespace + key)) else { continue }
            if let text = existing as? String {
                guard text.utf8.count <= ScriptWidgetAtomicPreferences.maximumValueBytes else { throw ScriptWidgetRecordError.invalidData }
                total += text.utf8.count; result[key] = text
            } else {
                let fingerprint = try Self.fingerprint(existing)
                total += fingerprint.count; unsupported[key] = fingerprint
            }
            guard total <= Self.maximumBackupBytes / 2 else { throw ScriptWidgetRecordError.invalidData }
        }
        return ScriptWidgetRecordSnapshot(values: result, unsupported: unsupported)
    }

    private static func fingerprint(_ value: Any) throws -> Data {
        var remaining = 10000
        func node(_ value: Any, depth: Int) throws -> [Any] {
            remaining -= 1
            guard remaining >= 0, depth <= 16 else { throw ScriptWidgetRecordError.invalidData }
            if let value = value as? String { return ["string", value] }
            if let value = value as? Data {
                guard value.count <= ScriptWidgetAtomicPreferences.maximumValueBytes else { throw ScriptWidgetRecordError.invalidData }
                return ["data", value.base64EncodedString()]
            }
            if let value = value as? Date { return ["date", String(value.timeIntervalSince1970)] }
            if let value = value as? NSNumber {
                return [CFGetTypeID(value) == CFBooleanGetTypeID() ? "bool" : "number", value.stringValue]
            }
            if let values = value as? [String: Any] {
                return ["dictionary", try values.keys.sorted().map { [ $0, try node(values[$0]!, depth: depth + 1) ] as [Any] }]
            }
            if let values = value as? [Any] { return ["array", try values.map { try node($0, depth: depth + 1) }] }
            throw ScriptWidgetRecordError.invalidData
        }
        let data = try JSONSerialization.data(withJSONObject: node(value, depth: 0), options: [.withoutEscapingSlashes])
        guard data.count <= maximumBackupBytes / 2 else { throw ScriptWidgetRecordError.invalidData }
        return data
    }

    func read() throws -> ScriptWidgetRecordSnapshot {
        try validateScope()
        guard let result = ScriptWidgetStorageLock.withExclusiveAccess(container: container, namespace: namespace, operation: { () -> Result<ScriptWidgetRecordSnapshot, Error> in
            guard defaults.synchronize() else { return .failure(ScriptWidgetRecordError.unavailable) }
            return Result {
                try validateScope()
                return try readValues()
            }
        }) else { throw ScriptWidgetRecordError.unavailable }
        return try result.get()
    }

    func apply(_ replacement: ScriptWidgetRecordSnapshot, expected: ScriptWidgetRecordSnapshot) throws {
        try validateScope()
        try validate(replacement)
        var failure: Error?
        let saved = ScriptWidgetAtomicPreferences.mutate(container: container, defaults: defaults, namespace: namespace) { store in
            do {
                try validateScope()
                guard try readValues(from: store) == expected else { throw ScriptWidgetRecordError.conflict }
                if executionSnapshot != nil {
                    let removals = Set(kind.keys).subtracting(replacement.values.keys)
                    guard try ScriptWidgetStorageNamespaces.fitsBudget(namespace: namespace, defaults: store,
                        replacing: replacement.values, removing: removals) else { throw ScriptWidgetRecordError.invalidData }
                }
            } catch { failure = error; return false }
            for key in kind.keys {
                if let value = replacement.values[key] { try store.writeValue(value, forKey: namespace + key) }
                else { try store.removeValue(forKey: namespace + key) }
            }
            return true
        }
        guard saved else { throw failure ?? ScriptWidgetRecordError.unavailable }
    }

    private var configurationByteLimit: Int { kind == .launcher ? 32768 : 4096 }

    func configuration(in snapshot: ScriptWidgetRecordSnapshot) throws -> [String: Any] {
        var raw = snapshot.values[Self.configurationKey] ?? ""
        if raw.isEmpty {
            guard kind == .wallpaper else { return kind.defaults }
            // Portable defaults are package data, never imported user records.
            // Saved native configuration always takes precedence, including errors.
            let result = package.readFileResult(fullPath: package.path.appendingPathComponent("wallpaper.json"))
            if let content = result.content { raw = content }
            else {
                guard result.icloud == .notInICloud else { throw ScriptWidgetRecordError.invalidData }
                return kind.defaults
            }
        }
        guard raw.utf8.count <= configurationByteLimit, let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              Set(object.keys) == ["version", "kind", "values"], Self.integer(object["version"], range: 1...1),
              object["kind"] as? String == kind.rawValue, let values = object["values"] as? [String: Any] else { throw ScriptWidgetRecordError.invalidData }
        try validateConfiguration(values)
        return values
    }

    func settingConfiguration(_ values: [String: Any], in snapshot: ScriptWidgetRecordSnapshot) throws -> ScriptWidgetRecordSnapshot {
        try validateConfiguration(values)
        var next = snapshot
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "kind": kind.rawValue, "values": values], options: [.sortedKeys, .withoutEscapingSlashes])
        guard bytes.count <= configurationByteLimit, let text = String(data: bytes, encoding: .utf8) else { throw ScriptWidgetRecordError.invalidData }
        next.values[Self.configurationKey] = text
        next.unsupported.removeValue(forKey: Self.configurationKey)
        return next
    }

    private func validateConfiguration(_ values: [String: Any]) throws {
        guard Set(values.keys) == Set(kind.defaults.keys) else { throw ScriptWidgetRecordError.invalidConfiguration(kind) }
        let valid: Bool
        switch kind {
        case .wallpaper:
            valid = Self.text(values["title"],limit:40,allowEmpty:true) && Self.text(values["caption"],limit:80,allowEmpty:true) && ["none","text","date"].contains(values["content"] as? String ?? "") && ["adaptive","light","dark"].contains(values["ink"] as? String ?? "") && ScriptWidgetWallpaperAsset.decode(values["backgrounds"]) != nil
        case .plantCare: valid = Self.text(values["title"], limit: 40) && Self.integer(values["intervalDays"], range: 1...30)
        case .pocketPet: valid = Self.text(values["title"], limit: 40)
        case .launcher:
            valid = ScriptWidgetLauncherItem.validTitle(values["title"]) && ["blue", "green", "rose"].contains(values["accent"] as? String ?? "") && ScriptWidgetLauncherItem.decode(values["items"]) != nil
        case .repoStats:
            valid = Self.validRepository(values["repository"]) && ["blue", "green", "rose"].contains(values["accent"] as? String ?? "")
        case .healthCard:
            valid = ["steps", "energy", "heart"].contains(values["metric"] as? String ?? "")
                && Self.integer(values["stepsGoal"], range: 1...100000) && Self.integer(values["energyGoal"], range: 1...10000)
        case .weather:
            let automatic = values["useLocation"] as? NSNumber
            valid = Self.text(values["city"], limit: 60, allowEmpty: true)
                && Self.number(values["latitude"], range: -90...90) && Self.number(values["longitude"], range: -180...180)
                && automatic.map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true
                && ["c", "f"].contains(values["unit"] as? String ?? "")
        case .photoCard:
            let photos = values["photos"] as? [String]
            valid = Self.text(values["title"], limit: 40) && Self.text(values["caption"], limit: 80, allowEmpty: true)
                && ["single", "duo", "grid"].contains(values["layout"] as? String ?? "")
                && photos.map { $0.count <= 4 && Set($0).count == $0.count && $0.allSatisfy { $0.range(of: "^photo-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil } } == true
        case .countdown:
            let date = values["targetDate"] as? String
            let repeatValue = values["repeatYearly"] as? NSNumber
            valid = Self.text(values["title"], limit: 40) && (date == "" || Self.validDate(date))
                && repeatValue.map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true
                && ["blue", "rose", "green"].contains(values["accent"] as? String ?? "")
        case .hydration: valid = Self.integer(values["goal"], range: 1...32) && Self.integer(values["glassML"], range: 25...2000)
        case .mood: valid = Self.text(values["intention"], limit: 80, allowEmpty: true)
        case .habitStreak: valid = Self.text(values["title"], limit: 40)
        case .habitHeatmap: valid = ["readName", "runName", "meditateName"].allSatisfy { Self.text(values[$0], limit: 40) }
        case .checklist:
            if let items = values["items"] as? [String] {
                valid = (1...8).contains(items.count) && Set(items).count == items.count && items.allSatisfy {
                    Self.text($0, limit: 60) && Data($0.utf8) == Data($0.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.utf8)
                }
            } else { valid = false }
        }
        guard valid else { throw ScriptWidgetRecordError.invalidConfiguration(kind) }
    }

    private static func validRepository(_ value: Any?) -> Bool {
        guard let value = value as? String, value.utf8.count <= 140 else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", options: .regularExpression) != nil,
              parts[1].range(of: "^[A-Za-z0-9_.-]{1,100}$", options: .regularExpression) != nil else { return false }
        return parts[1] != "." && parts[1] != ".."
    }

    private static func number(_ value: Any?, range: ClosedRange<Double>) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return false }
        return range.contains(number.doubleValue)
    }

    static func integer(_ value: Any?, range: ClosedRange<Int>) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue else { return false }
        return number.doubleValue >= Double(range.lowerBound) && number.doubleValue <= Double(range.upperBound)
    }

    private static func text(_ value: Any?, limit: Int, allowEmpty: Bool = false) -> Bool {
        guard let text = value as? String, text.utf16.count <= limit else { return false }
        return allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func validDate(_ text: Any?) -> Bool {
        guard let text = text as? String, text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return false }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] >= 1970 else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
        guard let date = calendar.date(from: components) else { return false }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        return actual.year == parts[0] && actual.month == parts[1] && actual.day == parts[2]
    }

    private func validValue(_ value: Any?) -> Bool {
        switch kind {
        case .hydration: return Self.integer(value, range: 0...64000)
        case .mood: return Self.integer(value, range: 1...5)
        case .plantCare, .habitStreak: return Self.integer(value, range: 1...1)
        case .pocketPet:
            guard let actions=value as? [String] else { return false }
            return !actions.isEmpty && actions.count<=3 && Set(actions).count==actions.count && actions.allSatisfy { ["feed","play","rest"].contains($0) }
        case .checklist:
            guard let items = value as? [String] else { return false }
            return items.count <= 8 && Set(items).count == items.count && items.allSatisfy { Self.text($0, limit: 60) }
        case .habitHeatmap, .countdown, .photoCard, .weather, .healthCard, .repoStats, .launcher, .wallpaper: return false
        }
    }

    private func entries(raw: String) throws -> [[String: Any]] {
        if raw.isEmpty { return [] }
        guard raw.utf16.count <= 64000, let state = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              Set(state.keys) == ["version", "revision", "entries", "undo"], Self.integer(state["version"], range: 1...1),
              Self.integer(state["revision"], range: 0...9_007_199_254_740_991),
              let entries = state["entries"] as? [[String: Any]], entries.count <= 366 else { throw ScriptWidgetRecordError.invalidData }
        var dates = Set<String>()
        for entry in entries {
            guard Set(entry.keys) == ["date", "value"], Self.validDate(entry["date"]), let date = entry["date"] as? String,
                  dates.insert(date).inserted, validValue(entry["value"]) else { throw ScriptWidgetRecordError.invalidData }
        }
        if !(state["undo"] is NSNull) {
            guard let undo = state["undo"] as? [String: Any], Set(undo.keys) == ["date", "value"], Self.validDate(undo["date"]),
                  undo["value"] is NSNull || validValue(undo["value"]) else { throw ScriptWidgetRecordError.invalidData }
        }
        return entries
    }

    func rows(in snapshot: ScriptWidgetRecordSnapshot) throws -> [ScriptWidgetRecordRow] {
        guard snapshot.unsupported.isEmpty else { throw ScriptWidgetRecordError.invalidData }
        var rows: [ScriptWidgetRecordRow] = []
        let names = (try? configuration(in: snapshot)) ?? kind.defaults
        for key in kind.keys where key != Self.configurationKey && !key.hasPrefix("habit.") {
            guard let raw = snapshot.values[key], !raw.isEmpty else { continue }
            if kind == .habitHeatmap {
                guard let days = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String], days.count <= 3660,
                      days.allSatisfy({ Self.validDate($0) }) else { throw ScriptWidgetRecordError.invalidData }
                for date in Set(days) {
                    rows.append(.init(id: key + date, date: date, label: names[String(key.split(separator: ".").last ?? "read") + "Name"] as? String ?? "Habit", value: "✓"))
                }
            } else {
                for entry in try entries(raw: raw) {
                    let date = entry["date"] as! String
                    let value: String
                    switch kind {
                    case .hydration: value = "\((entry["value"] as! NSNumber).intValue) mL"
                    case .mood: value = ["Low", "Uneasy", "Okay", "Good", "Great"][(entry["value"] as! NSNumber).intValue - 1]
                    case .checklist, .pocketPet: value = (entry["value"] as! [String]).joined(separator: ", ")
                    default: value = "✓"
                    }
                    rows.append(.init(id: key + date, date: date, label: kind.title, value: value))
                }
            }
        }
        return rows.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }

    func validate(_ snapshot: ScriptWidgetRecordSnapshot) throws {
        guard snapshot.unsupported.isEmpty, Set(snapshot.values.keys).isSubset(of: Set(kind.keys)), snapshot.values.values.allSatisfy({ $0.utf8.count <= ScriptWidgetAtomicPreferences.maximumValueBytes }),
              snapshot.values.values.reduce(0, { $0 + $1.utf8.count }) <= Self.maximumBackupBytes / 2 else { throw ScriptWidgetRecordError.invalidData }
        _ = try configuration(in: snapshot)
        _ = try rows(in: snapshot)
        if kind == .habitStreak {
            guard ["habit.lastDate", "habit.streak"].allSatisfy({ (snapshot.values[$0]?.utf8.count ?? 0) <= 256 }) else { throw ScriptWidgetRecordError.invalidData }
        }
    }

    /// Even corrupt string records may be exported for safekeeping. Only a
    /// fully validated backup can be restored; unrelated preference keys never export.
    func backup(_ snapshot: ScriptWidgetRecordSnapshot, now: Date = Date()) throws -> Data {
        try validateScope()
        guard Set(snapshot.values.keys).union(snapshot.unsupported.keys).isSubset(of: Set(kind.keys)) else { throw ScriptWidgetRecordError.invalidData }
        let object: [String: Any] = ["formatVersion": 1, "kind": kind.rawValue, "packageName": package.name,
                                     "createdAt": ISO8601DateFormatter().string(from: now), "values": snapshot.values,
                                     "unsupportedValues": snapshot.unsupported.mapValues { $0.base64EncodedString() }]
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        guard bytes.count <= Self.maximumBackupBytes else { throw ScriptWidgetRecordError.invalidData }
        return bytes
    }

    func previewRestore(_ data: Data) throws -> ScriptWidgetRecordRestore {
        guard data.count <= Self.maximumBackupBytes, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["formatVersion", "kind", "packageName", "createdAt", "values", "unsupportedValues"], Self.integer(object["formatVersion"], range: 1...1),
              let source = object["packageName"] as? String, ScriptWidgetPackageName.isValid(source),
              let createdAt = object["createdAt"] as? String, createdAt.count <= 40, ISO8601DateFormatter().date(from: createdAt) != nil,
              let values = object["values"] as? [String: String], let unsupported = object["unsupportedValues"] as? [String: String], unsupported.isEmpty else { throw ScriptWidgetRecordError.invalidBackup }
        guard object["kind"] as? String == kind.rawValue else { throw ScriptWidgetRecordError.wrongKind }
        let snapshot = ScriptWidgetRecordSnapshot(values: values)
        do { try validate(snapshot) } catch { throw ScriptWidgetRecordError.invalidBackup }
        return .init(sourceName: source, createdAt: createdAt, snapshot: snapshot, rows: try rows(in: snapshot))
    }

    static func readBackup(at url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ScriptWidgetRecordError.invalidBackup }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink <= 1,
              info.st_size >= 0, info.st_size <= Self.maximumBackupBytes else { throw ScriptWidgetRecordError.invalidBackup }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw ScriptWidgetRecordError.invalidBackup }
            if count == 0 { return data }
            guard data.count <= Self.maximumBackupBytes - count else { throw ScriptWidgetRecordError.invalidBackup }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}


/// Bounded still-photo preparation shared by native file/Photos pickers.
/// Decode orientation into a thumbnail, crop within its pixels and re-encode;
/// original metadata is never copied to the widget package.
enum ScriptWidgetPhotoPreparation {
    static let maximumInputBytes = 25 * 1_024 * 1_024
    static func load(url: URL, maximumPixelSize: Int = 1536) throws -> CGImage {
        guard url.isFileURL, let bytes = ScriptWidgetPackageFiles.read(root: url.deletingLastPathComponent().resolvingSymlinksInPath(),
            relative: url.lastPathComponent, maximumBytes: maximumInputBytes) else { throw ScriptWidgetRecordError.invalidData }
        return try load(data: bytes, maximumPixelSize: maximumPixelSize)
    }
    static func load(data: Data, maximumPixelSize: Int = 1536) throws -> CGImage {
        guard data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0, width.doubleValue <= 20_000, height.doubleValue <= 20_000,
              width.doubleValue * height.doubleValue <= 100_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(3072, max(32, maximumPixelSize)), kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ScriptWidgetRecordError.invalidData }
        return image
    }
    static func crop(_ image: CGImage, zoom: Double, horizontal: Double, vertical: Double) throws -> CGImage {
        guard zoom.isFinite, (1...4).contains(zoom), horizontal.isFinite, (0...1).contains(horizontal),
              vertical.isFinite, (0...1).contains(vertical) else { throw ScriptWidgetRecordError.invalidData }
        let side = max(1, floor(Double(min(image.width, image.height)) / zoom))
        let rect = CGRect(x: floor((Double(image.width) - side) * horizontal),
            y: floor((Double(image.height) - side) * vertical), width: side, height: side)
        guard let cropped = image.cropping(to: rect) else { throw ScriptWidgetRecordError.invalidData }
        let outputSize = min(768, cropped.width)
        guard let context = CGContext(data: nil, width: outputSize, height: outputSize, bitsPerComponent: 8,
            bytesPerRow: outputSize * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScriptWidgetRecordError.unavailable }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outputSize, height: outputSize))
        guard let result = context.makeImage() else { throw ScriptWidgetRecordError.unavailable }
        return result
    }
    static func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw ScriptWidgetRecordError.unavailable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= maximumInputBytes else { throw ScriptWidgetRecordError.invalidData }
        return data as Data
    }
}

/// Native configuration for user-triggered links; this does not grant network or script execution access.
struct ScriptWidgetLauncherItem: Identifiable, Equatable {
    var id: String
    var title: String
    var icon: String
    var type: String
    var target: String
    var input: String

    static let icons = ["globe", "map.fill", "play.fill", "star.fill", "music.note", "envelope.fill", "phone.fill", "message.fill", "house.fill", "checkmark.circle.fill"]
    static let defaults: [Self] = [
        .init(id:"github",title:"GitHub",icon:"globe",type:"web",target:"https://github.com",input:""),
        .init(id:"maps",title:"Maps",icon:"map.fill",type:"app",target:"maps://",input:""),
        .init(id:"search",title:"Search",icon:"star.fill",type:"web",target:"https://www.google.com",input:"")
    ]
    var dictionary: [String:String] { ["id":id,"title":title,"icon":icon,"type":type,"target":target,"input":input] }

    private static func plain(_ value: String, maximum: Int, empty: Bool = false) -> Bool {
        value.utf16.count <= maximum && (empty || !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func validTitle(_ value: Any?) -> Bool {
        guard let value=value as? String else { return false };return plain(value,maximum:40)
    }

    static func decode(_ value: Any?) -> [Self]? {
        guard let items=value as? [[String:Any]], (1...6).contains(items.count) else { return nil }
        var result:[Self]=[]
        for fields in items {
            guard Set(fields.keys)==["id","title","icon","type","target","input"],
                  let id=fields["id"] as? String,let title=fields["title"] as? String,let icon=fields["icon"] as? String,
                  let type=fields["type"] as? String,let target=fields["target"] as? String,let input=fields["input"] as? String else { return nil }
            let item=Self(id:id,title:title,icon:icon,type:type,target:target,input:input)
            guard (try? item.destination()) != nil, !result.contains(where:{$0.id==id}) else { return nil }
            result.append(item)
        }
        return result
    }

    func destination() throws -> URL {
        func invalid() -> ScriptWidgetRecordError { .invalidConfiguration(.launcher) }
        guard id.range(of:"^[A-Za-z0-9][A-Za-z0-9-]{0,39}$",options:.regularExpression) != nil,
              Self.plain(title,maximum:24),Self.icons.contains(icon),["web","app","shortcut"].contains(type),
              input.utf16.count<=500,!input.unicodeScalars.contains(where:{$0.value==0}) else { throw invalid() }
        if type=="shortcut" {
            guard Self.plain(target,maximum:128) else { throw invalid() }
            let unreserved=CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            guard let name=target.addingPercentEncoding(withAllowedCharacters:unreserved),let text=input.addingPercentEncoding(withAllowedCharacters:unreserved),
                  let url=URL(string:"shortcuts://run-shortcut?name="+name+(input.isEmpty ? "" : "&input=text&text="+text)) else { throw invalid() }
            return url
        }
        guard input.isEmpty,Self.plain(target,maximum:2048),!target.contains("\\"),!target.contains(where:{$0.isWhitespace}),
              target.range(of:"%(?![0-9A-Fa-f]{2})",options:.regularExpression)==nil,
              let parts=URLComponents(string:target),let scheme=parts.scheme?.lowercased(),parts.user==nil,parts.password==nil,
              let url=parts.url else { throw invalid() }
        if type=="web" {
            guard ["http","https"].contains(scheme),let host=parts.host,!host.isEmpty,
                  target.range(of:"^https?://(?:[A-Za-z0-9.-]+|\\[[0-9A-Fa-f:.]+\\])(?::[0-9]{1,5})?(?:[/?#]|$)",options:.caseInsensitive.union(.regularExpression)) != nil,
                  parts.port.map({(1...65535).contains($0)}) ?? true else { throw invalid() }
        } else {
            guard scheme.range(of:"^[a-z][a-z0-9+.-]*$",options:.regularExpression) != nil,
                  !["http","https","file","data","javascript","about","blob","widget-deeplink","scriptwidget","prefs","app-prefs"].contains(scheme) else { throw invalid() }
        }
        return url
    }
}


/// Closed native configuration: filenames cannot escape the package or select another resource class.
struct ScriptWidgetWallpaperAsset: Identifiable, Equatable, Sendable {
    var family: String
    var appearance: String
    var image: String
    var label: String
    var id: String { family+"."+appearance }
    var dictionary: [String:Any] { ["family":family,"appearance":appearance,"image":image,"label":label] }
    static let families=["small","medium","large","extraLarge","extraLargePortrait"]
    static func familyTitle(_ family:String)->String {
        switch family { case "small":return "Small";case "medium":return "Medium";case "large":return "Large";case "extraLarge":return "Extra large";case "extraLargePortrait":return "Extra large portrait";default:return "Unknown size" }
    }
    static func validImage(_ name:String)->Bool { ScriptWidgetPackage.isWallpaperImageName(name) }
    static func validLabel(_ value:String)->Bool {
        value.utf16.count<=30 && !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && value.unicodeScalars.allSatisfy{!CharacterSet.controlCharacters.contains($0)}
    }
    static func decode(_ value:Any?)->[Self]? {
        guard let rows=value as? [[String:Any]],rows.count<=10 else { return nil }
        var result:[Self]=[],seen=Set<String>()
        for row in rows {
            guard Set(row.keys)==["family","appearance","image","label"],let family=row["family"] as? String,families.contains(family),
                  let appearance=row["appearance"] as? String,["light","dark"].contains(appearance),let image=row["image"] as? String,validImage(image),
                  let label=row["label"] as? String,validLabel(label) else { return nil }
            let item=Self(family:family,appearance:appearance,image:image,label:label)
            guard seen.insert(item.id).inserted else { return nil };result.append(item)
        }
        return result
    }
}

/// Working-image pixel coordinates. No device-position table is guessed or persisted.
struct ScriptWidgetWallpaperCrop: Equatable, Sendable {
    var x:Int
    var y:Int
    var width:Int
    var height:Int
    func rectangle(imageWidth:Int,imageHeight:Int) throws -> CGRect {
        guard imageWidth>0,imageHeight>0,x>=0,y>=0,width>0,height>0,width<=imageWidth,height<=imageHeight,
              x<=imageWidth-width,y<=imageHeight-height else { throw ScriptWidgetRecordError.invalidData }
        return CGRect(x:x,y:y,width:width,height:height)
    }
    static func initial(family:String,imageWidth:Int,imageHeight:Int)->Self {
        let ratio:Double=family=="small" ? 1 : family=="large" ? 0.95 : family=="extraLargePortrait" ? 0.7 : 2.14
        var width=max(1,Int(Double(imageWidth)*(family=="small" ? 0.42 : 0.86))),height=max(1,Int(Double(width)/ratio))
        if height>imageHeight { height=imageHeight;width=max(1,min(imageWidth,Int(Double(height)*ratio))) }
        return .init(x:(imageWidth-width)/2,y:(imageHeight-height)/2,width:width,height:height)
    }
    func cropped(_ image:CGImage) throws -> CGImage {
        let rect=try rectangle(imageWidth:image.width,imageHeight:image.height)
        guard let part=image.cropping(to:rect) else { throw ScriptWidgetRecordError.invalidData }
        let scale=min(1,1024/Double(max(part.width,part.height))),w=max(1,Int((Double(part.width)*scale).rounded())),h=max(1,Int((Double(part.height)*scale).rounded()))
        guard let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScriptWidgetRecordError.unavailable }
        context.interpolationQuality = .high;context.draw(part,in:CGRect(x:0,y:0,width:w,height:h))
        guard let result=context.makeImage() else { throw ScriptWidgetRecordError.unavailable };return result
    }
}
