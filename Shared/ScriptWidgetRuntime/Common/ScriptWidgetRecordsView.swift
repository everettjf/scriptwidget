import SwiftUI
import UniformTypeIdentifiers
import WidgetKit
import PhotosUI
import CoreTransferable
import MapKit

private struct ScriptWidgetRecordDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor
final class ScriptWidgetRecordsModel: ObservableObject {
    struct PendingRestore {
        let backup: ScriptWidgetRecordRestore
        let expected: ScriptWidgetRecordSnapshot
    }
    let package: ScriptWidgetPackage
    private(set) var store: ScriptWidgetRecordStore?
    @Published var snapshot: ScriptWidgetRecordSnapshot?
    @Published var rows: [ScriptWidgetRecordRow] = []
    @Published var pending: PendingRestore?
    @Published var message: String?
    @Published var isError = false
    @Published var careIntervalDays = 3
    @Published var goal = 8
    @Published var glassML = 250
    @Published var intention = ""
    @Published var habitTitle = ""
    @Published var itemsText = ""
    @Published var readName = ""
    @Published var runName = ""
    @Published var meditateName = ""
    @Published var countdownDate = Date()
    @Published var repeatYearly = false
    @Published var accent = "blue"
    @Published var launcherItems = ScriptWidgetLauncherItem.defaults
    @Published private(set) var launcherTestMessage: String?
    @Published private(set) var launcherTestFailed = false
    @Published var repository = "everettjf/ScriptWidget"
    @Published var healthMetric = "steps"
    @Published var stepsGoal = 8000
    @Published var energyGoal = 500
    @Published var weatherCity = ""
    @Published var weatherLatitude = 0.0
    @Published var weatherLongitude = 0.0
    @Published var weatherUseLocation = true
    @Published var weatherUnit = "c"
    @Published var cityQuery = ""
    @Published private(set) var cityResults: [ScriptWidgetWeatherCity] = []
    @Published private(set) var isSearchingCity = false
    @Published private(set) var citySearchMessage: String?

    func searchCities() async {
        let query = cityQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSearchingCity else { return }
        guard (2...80).contains(query.utf16.count) else { citySearchMessage = "Enter 2–80 characters to find a city."; return }
        isSearchingCity = true; cityResults = []; citySearchMessage = nil
        defer { isSearchingCity = false }
        do {
            let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query; request.resultTypes = .address
            let response = try await MKLocalSearch(request: request).start()
            guard cityQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            var seen = Set<String>()
            cityResults = response.mapItems.prefix(5).compactMap { item in
                let coordinate = item.placemark.coordinate
                guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                var name = String((item.placemark.locality ?? item.name ?? query).trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.prefix(60))
                while name.utf16.count > 60 { name.removeLast() }
                guard !name.isEmpty else { return nil }
                let city = ScriptWidgetWeatherCity(name: name, latitude: (coordinate.latitude * 100).rounded() / 100,
                    longitude: (coordinate.longitude * 100).rounded() / 100)
                return seen.insert(city.id).inserted ? city : nil
            }
            if cityResults.isEmpty { citySearchMessage = "No cities found. Enter a label and coordinates below." }
        } catch { citySearchMessage = "City search is unavailable. Enter a label and coordinates below." }
    }
    func chooseCity(_ city: ScriptWidgetWeatherCity) {
        weatherCity = city.name; weatherLatitude = city.latitude; weatherLongitude = city.longitude
        cityResults = []; citySearchMessage = "City selected. Save Configuration to use it."
    }
    @Published var wallpaperContent="none"
    @Published var wallpaperInk="adaptive"
    @Published var wallpaperBackgrounds:[ScriptWidgetWallpaperAsset]=[]
    @Published var wallpaperAssets:[ImageModel]=[]
    func reloadWallpaperAssets() { wallpaperAssets=package.getImageList().filter{ScriptWidgetWallpaperAsset.validImage($0.name) && $0.path.pathExtension=="png"} }
    func addWallpaperCrop(_ image:CGImage,family:String,appearance:String,label:String)->Bool {
        guard kind == .wallpaper,ScriptWidgetWallpaperAsset.families.contains(family),["light","dark"].contains(appearance),ScriptWidgetWallpaperAsset.validLabel(label) else { report(ScriptWidgetRecordError.invalidConfiguration(.wallpaper));return false }
        guard let name=package.saveWallpaperImage(image) else { report(ScriptWidgetRecordError.unavailable);return false }
        let asset=ScriptWidgetWallpaperAsset(family:family,appearance:appearance,image:name,label:label)
        wallpaperBackgrounds.removeAll{$0.id==asset.id};wallpaperBackgrounds.append(asset);reloadWallpaperAssets();cachePhotoResources()
        succeeded("Crop added. Save Configuration to apply it to this size and appearance.");return true
    }
    var protectedWallpaperNames:Set<String> {
        let draft=wallpaperBackgrounds.map(\.image)
        guard let snapshot,let store,let config=try? store.configuration(in:snapshot),let saved=ScriptWidgetWallpaperAsset.decode(config["backgrounds"]) else { return Set(draft+wallpaperAssets.map(\.name)) }
        return Set(draft+saved.map(\.image))
    }
    func deleteUnusedWallpaper(_ name:String) {
        guard ScriptWidgetWallpaperAsset.validImage(name),!protectedWallpaperNames.contains(name) else { return }
        let result=package.deleteImage(name:name)
        if result.0 { reloadWallpaperAssets();cachePhotoResources();succeeded("Unused crop removed.") } else { message=result.1;isError=true }
    }
    @Published var photoCaption = ""
    @Published var photoLayout = "single"
    @Published var photoNames: [String] = []
    @Published var photoAssets: [ImageModel] = []

    var orderedPhotoAssets: [ImageModel] {
        photoNames.compactMap { name in photoAssets.first { $0.name == name } } + photoAssets.filter { !photoNames.contains($0.name) }
    }
    func movePhoto(_ name: String, offset: Int) {
        guard let index = photoNames.firstIndex(of: name), photoNames.indices.contains(index + offset) else { return }
        photoNames.swapAt(index, index + offset)
    }
    func reloadPhotoAssets() {
        photoAssets = package.getImageList().filter { $0.name.hasPrefix("photo-") && $0.path.pathExtension.lowercased() == "png" }
    }
    func addPhoto(_ image: CGImage) -> Bool {
        guard let name = package.savePhotoImage(image) else {
            message = "The photo could not be saved. Keep at most 12 imported photos, or reopen the widget if its installation changed."
            isError = true; return false
        }
        reloadPhotoAssets()
        if photoNames.count < 4 { photoNames.append(name) }
        succeeded("Photo imported. Save Configuration to use your selection.")
        cachePhotoResources()
        return true
    }
    var protectedPhotoNames: Set<String> {
        guard let snapshot, let store, let config = try? store.configuration(in: snapshot), let saved = config["photos"] as? [String] else {
            return Set(photoNames + photoAssets.map(\.name))
        }
        return Set(photoNames + saved)
    }
    func deleteUnusedPhoto(_ name: String) {
        guard !protectedPhotoNames.contains(name) else { return }
        let result = package.deleteImage(name: name)
        if result.0 { reloadPhotoAssets(); succeeded("Unused photo removed."); cachePhotoResources() }
        else { message = result.1; isError = true }
    }
    private func cachePhotoResources() {
        guard let scope = package.managedScope, (try? scope.validate(name: package.name)) != nil,
              !ScriptWidgetApplicationTestHost.isActive else { return }
        let manager = sharedScriptManager, package = self.package
        guard manager.storageContext?.locationIdentifier == scope.context.locationIdentifier else { return }
        Task.detached(priority: .utility) {
            _ = manager.precachePackageFiles(package)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func prepareLauncherTest(id: String) -> (ScriptWidgetLauncherItem, URL)? {
        do {
            guard kind == .launcher, let store, let item=launcherItems.first(where:{$0.id==id}) else { throw ScriptWidgetRecordError.invalidTemplate }
            _ = try store.read()
            let url=try item.destination()
            launcherTestMessage=nil;launcherTestFailed=false
            return (item,url)
        } catch { report(error);return nil }
    }

    func finishLauncherTest(item: ScriptWidgetLauncherItem, accepted: Bool) {
        guard launcherItems.contains(item) else { return }
        do {
            guard let store else { throw ScriptWidgetRecordError.unavailable }
            _ = try store.read()
            launcherTestFailed = !accepted
            launcherTestMessage = accepted ? "The system accepted the link. Check the target app to confirm completion." : "Couldn’t open this link. Check the URL and make sure the target app is installed."
        } catch { report(error) }
    }

    static var countdownDateRange: ClosedRange<Date> {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let start = calendar.date(from: DateComponents(year: 1970, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: 9999, month: 12, day: 31, hour: 23, minute: 59, second: 59))!
        return start...end
    }

    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    init(package: ScriptWidgetPackage, store: ScriptWidgetRecordStore? = nil) {
        self.package = package
        self.store = store
        do { if self.store == nil { self.store = try .live(package: package) }; reload() }
        catch { report(error) }
    }
    var kind: ScriptWidgetRecordKind? { store?.kind }
    var legacyNote: String? {
        guard kind == .habitStreak, let values = snapshot?.values,
              values["habit.lastDate"] != nil || values["habit.streak"] != nil else { return nil }
        if let count = values["habit.streak"], count.utf8.count <= 6, count.range(of: "^[0-9]{1,6}$", options: .regularExpression) != nil {
            return "Earlier automatic count: \(count) (unverified). Original values are preserved."
        }
        return "Earlier automatic records are preserved. They are not verified check-ins."
    }
    func report(_ error: Error) {
        if (error as? CocoaError)?.code == .userCancelled { return }
        message = error.localizedDescription; isError = true
    }
    var restoreConfigurationSummary: String? {
        guard let store, let pending, let values = try? store.configuration(in: pending.backup.snapshot) else { return nil }
        switch store.kind {
        case .wallpaper: return "\(values["title"] as? String ?? "") · \((values["backgrounds"] as? [Any])?.count ?? 0) size/appearance crops"
        case .plantCare: return "\(values["title"] as? String ?? "") · every \(values["intervalDays"] as? Int ?? 3) days"
        case .pocketPet: return values["title"] as? String
        case .launcher: return "\(values["title"] as? String ?? "") · \((values["items"] as? [Any])?.count ?? 0) links"
        case .repoStats: return values["repository"] as? String
        case .healthCard: return "\(values["metric"] as? String ?? "steps") · \(values["stepsGoal"] as? Int ?? 8000) steps · \(values["energyGoal"] as? Int ?? 500) kcal"
        case .weather: return "\(values["city"] as? String ?? "") · \(values["unit"] as? String ?? "c") · \((values["useLocation"] as? Bool ?? true) ? "Location with saved-city fallback" : "Saved city")"
        case .photoCard: return "\(values["title"] as? String ?? "") · \((values["photos"] as? [String])?.count ?? 0) photos · \(values["layout"] as? String ?? "single")\n\(values["caption"] as? String ?? "")"
        case .countdown: return "\(values["title"] as? String ?? "") · \(values["targetDate"] as? String ?? "")"
        case .hydration: return "\(values["goal"] as? Int ?? 8) glasses, \(values["glassML"] as? Int ?? 250) mL each"
        case .mood: return values["intention"] as? String
        case .habitStreak: return values["title"] as? String
        case .checklist: return (values["items"] as? [String])?.joined(separator: ", ")
        case .habitHeatmap: return ["readName", "runName", "meditateName"].compactMap { values[$0] as? String }.joined(separator: ", ")
        }
    }
    private func succeeded(_ text: String) { message = text; isError = false }

    func reload() {
        guard let store else { return }
        message = nil; isError = false
        do {
            let current = try store.read()
            snapshot = current
            let config: [String: Any]
            do { config = try store.configuration(in: current) }
            catch { config = store.kind.defaults; report(error) }
            launcherItems = ScriptWidgetLauncherItem.decode(config["items"]) ?? ScriptWidgetLauncherItem.defaults
            launcherTestMessage = nil
            repository = config["repository"] as? String ?? "everettjf/ScriptWidget"
            healthMetric = config["metric"] as? String ?? "steps"
            stepsGoal = config["stepsGoal"] as? Int ?? 8000
            energyGoal = config["energyGoal"] as? Int ?? 500
            weatherCity = config["city"] as? String ?? ""
            weatherLatitude = config["latitude"] as? Double ?? 0
            weatherLongitude = config["longitude"] as? Double ?? 0
            weatherUseLocation = config["useLocation"] as? Bool ?? true
            weatherUnit = config["unit"] as? String ?? "c"
            photoCaption = config["caption"] as? String ?? ""
            photoLayout = config["layout"] as? String ?? "single"
            photoNames = config["photos"] as? [String] ?? []
            if kind == .photoCard { reloadPhotoAssets() }
            wallpaperContent=config["content"] as? String ?? "none";wallpaperInk=config["ink"] as? String ?? "adaptive"
            wallpaperBackgrounds=ScriptWidgetWallpaperAsset.decode(config["backgrounds"]) ?? []
            if kind == .wallpaper { reloadWallpaperAssets() }
            careIntervalDays = config["intervalDays"] as? Int ?? 3
            goal = config["goal"] as? Int ?? 8; glassML = config["glassML"] as? Int ?? 250
            countdownDate = Self.dateFormatter().date(from: config["targetDate"] as? String ?? "") ?? Date()
            repeatYearly = config["repeatYearly"] as? Bool ?? false
            accent = config["accent"] as? String ?? "blue"
            intention = config["intention"] as? String ?? ""
            habitTitle = config["title"] as? String ?? ""
            itemsText = (config["items"] as? [String] ?? []).joined(separator: "\n")
            readName = config["readName"] as? String ?? ""; runName = config["runName"] as? String ?? ""; meditateName = config["meditateName"] as? String ?? ""
            do { rows = try store.rows(in: current) }
            catch { rows = []; report(error) }
        } catch { snapshot = nil; rows = []; report(error) }
    }

    func saveConfiguration() {
        guard let store, let snapshot else { return }
        let values: [String: Any]
        switch store.kind {
        case .wallpaper: values = ["title":habitTitle,"caption":photoCaption,"content":wallpaperContent,"ink":wallpaperInk,"backgrounds":wallpaperBackgrounds.map(\.dictionary)]
        case .plantCare: values = ["title": habitTitle, "intervalDays": careIntervalDays]
        case .pocketPet: values = ["title": habitTitle]
        case .launcher: values = ["title": habitTitle, "accent": accent, "items": launcherItems.map(\.dictionary)]
        case .repoStats: values = ["repository": repository, "accent": accent]
        case .healthCard: values = ["metric": healthMetric, "stepsGoal": stepsGoal, "energyGoal": energyGoal]
        case .weather: values = ["city": weatherCity, "latitude": weatherLatitude, "longitude": weatherLongitude, "useLocation": weatherUseLocation, "unit": weatherUnit]
        case .photoCard: values = ["title": habitTitle, "caption": photoCaption, "layout": photoLayout, "photos": photoNames]
        case .countdown: values = ["title": habitTitle, "targetDate": Self.dateFormatter().string(from: countdownDate), "repeatYearly": repeatYearly, "accent": accent]
        case .hydration: values = ["goal": goal, "glassML": glassML]
        case .mood: values = ["intention": intention]
        case .habitStreak: values = ["title": habitTitle]
        case .habitHeatmap: values = ["readName": readName, "runName": runName, "meditateName": meditateName]
        case .checklist:
            values = ["items": itemsText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping }]
        }
        do {
            try store.apply(store.settingConfiguration(values, in: snapshot), expected: snapshot)
            reload(); succeeded("Configuration saved. Widgets will refresh when the system schedules them.")
            WidgetCenter.shared.reloadAllTimelines()
        } catch { report(error) }
    }

    func exportBackup(now: Date = Date()) throws -> Data {
        guard let store else { throw ScriptWidgetRecordError.unavailable }
        return try store.backup(store.read(), now: now)
    }
    func previewRestore(_ data: Data) {
        guard let store else { return }
        do {
            let backup = try store.previewRestore(data)
            pending = PendingRestore(backup: backup, expected: try store.read())
            succeeded("Review the backup before replacing local records.")
        } catch { pending = nil; report(error) }
    }
    func restore() {
        guard let store, let pending else { return }
        do {
            try store.apply(pending.backup.snapshot, expected: pending.expected)
            self.pending = nil; reload(); succeeded("Records restored.")
            WidgetCenter.shared.reloadAllTimelines()
        } catch { self.pending = nil; report(error) }
    }
}

struct ScriptWidgetRecordsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ScriptWidgetRecordsModel
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var confirmingRestore = false
    @State private var document = ScriptWidgetRecordDocument()
    @State private var exportFilename = ""
    @State private var visibleRows = 100

    init(package: ScriptWidgetPackage, store: ScriptWidgetRecordStore? = nil) {
        _model = StateObject(wrappedValue: ScriptWidgetRecordsModel(package: package, store: store))
    }

    init(model: ScriptWidgetRecordsModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.package.name).font(.headline)
                    Text("Records are local to this widget package. Backups are separate from exported script packages.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let message = model.message { Text(message).foregroundStyle(model.isError ? Color.red : Color.secondary).accessibilityIdentifier("record-status") }
                }
                if let kind = model.kind, model.snapshot != nil {
                    if let pending = model.pending {
                        Section("Restore Preview") {
                            LabeledContent("Source widget", value: pending.backup.sourceName)
                            LabeledContent("Saved at", value: ISO8601DateFormatter().date(from: pending.backup.createdAt)?.formatted(date: .abbreviated, time: .shortened) ?? pending.backup.createdAt)
                            LabeledContent("Daily records", value: String(pending.backup.rows.count))
                            if let summary = model.restoreConfigurationSummary { Text("Configuration: \(summary)").font(.footnote) }
                            Text("Replace records and configuration for \(model.package.name). Values missing from the backup will be removed. Export a current backup first if you need to keep them.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Replace Local Records", role: .destructive) { confirmingRestore = true }
                                .accessibilityIdentifier("record-restore-preview")
                            Button("Cancel Restore", role: .cancel) { model.pending = nil }
                        }
                    }
                    Section {
                        configuration(kind)
                        Button("Save Configuration", action: model.saveConfiguration)
                            .accessibilityIdentifier("record-save-configuration")
                    } header: { Text("Configuration") } footer: {
                        Text(kind == .habitHeatmap ? "Use up to 40 characters for each name. Renaming a habit keeps its existing history." : "These defaults apply when a widget instance's parameter is empty. An instance parameter takes priority.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Section("Backup & Restore") {
                        Button("Export Record Backup…") {
                            do {
                                let now = Date()
                                document = ScriptWidgetRecordDocument(data: try model.exportBackup(now: now))
                                exportFilename = model.package.name + "-records-" + ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "") + ".json"
                                showingExporter = true
                            }
                            catch { model.report(error) }
                        }.accessibilityIdentifier("record-export")
                        Button("Choose Backup to Restore…") { showingImporter = true }
                            .accessibilityIdentifier("record-import")
                        if let note = model.legacyNote { Text(note).font(.footnote).foregroundStyle(.secondary) }
                    }
                    if kind != .countdown && kind != .photoCard && kind != .weather && kind != .healthCard && kind != .repoStats && kind != .launcher { Section("History (\(model.rows.count))") {
                        if model.rows.isEmpty { Text("No recorded days yet. Use the widget's buttons to record an entry.").foregroundStyle(.secondary) }
                        ForEach(Array(model.rows.prefix(visibleRows))) { row in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.date).monospacedDigit()
                                    if kind == .habitHeatmap { Text(row.label).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text(row.value.isEmpty ? "No items checked" : row.value).multilineTextAlignment(.trailing)
                            }
                        }
                        if visibleRows < model.rows.count { Button("Show More History") { visibleRows += 100 } }
                    } }
                }
            }
            .navigationTitle("Records")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Reload", action: model.reload) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, idealWidth: 640, minHeight: 600, idealHeight: 740)
        #endif
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                model.previewRestore(try ScriptWidgetRecordStore.readBackup(at: url))
            } catch { model.report(error) }
        }
        .fileExporter(isPresented: $showingExporter, document: document, contentType: .json,
                      defaultFilename: exportFilename) { result in
            if case .failure(let error) = result { model.report(error) }
        }
        .confirmationDialog("Replace this widget's local records?", isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("Replace Records", role: .destructive, action: model.restore)
            Button("Cancel", role: .cancel) { }
        } message: { Text("This replaces the selected package's records and configuration with the previewed backup. Other packages are not changed.") }
    }

    @ViewBuilder
    private func configuration(_ kind: ScriptWidgetRecordKind) -> some View {
        switch kind {
        case .wallpaper:
            ScriptWidgetWallpaperConfigurationView(model:model)
        case .plantCare:
            TextField("Plant name (up to 40 characters)", text: $model.habitTitle)
            Stepper("Care interval: \(model.careIntervalDays) days", value: $model.careIntervalDays, in: 1...30)
            Text("Your personal care schedule. Only explicit check-ins create records; the illustration does not measure a real plant’s health.").font(.caption).foregroundStyle(.secondary)
        case .pocketPet:
            TextField("Pet name (up to 40 characters)", text: $model.habitTitle)
            Text("A local virtual companion. Feed, play and rest each count once per calendar day; Undo can revert the last change.").font(.caption).foregroundStyle(.secondary)
        case .launcher:
            ScriptWidgetLauncherConfigurationView(model: model)
        case .repoStats:
            LabeledContent("Public repository") { TextField("owner/repository", text: $model.repository).multilineTextAlignment(.trailing) }
            Picker("Accent", selection: $model.accent) { Text("Blue").tag("blue"); Text("Green").tag("green"); Text("Rose").tag("rose") }
            Text("Uses the public GitHub API without an account. Requests share GitHub’s anonymous IP rate limit. Cached counts and their check time remain visible offline; private repositories are unavailable.").font(.caption).foregroundStyle(.secondary)
        case .healthCard:
            Picker("Metric", selection: $model.healthMetric) { Text("Steps").tag("steps"); Text("Active energy").tag("energy"); Text("Latest heart rate").tag("heart") }
            LabeledContent("Daily steps goal") { TextField("Steps", value: $model.stepsGoal, format: .number).multilineTextAlignment(.trailing) }
            LabeledContent("Active energy goal (kcal)") { TextField("kcal", value: $model.energyGoal, format: .number).multilineTextAlignment(.trailing) }
            Text("Enable Health access in ScriptWidget Settings on iPhone. Health readings are not saved in record backups. Heart rate is the latest available sample, not a live measurement.").font(.caption).foregroundStyle(.secondary)
        case .weather:
            ScriptWidgetWeatherConfigurationView(model: model)
        case .photoCard:
            ScriptWidgetPhotoConfigurationView(model: model)
        case .countdown:
            TextField("Event name (up to 40 characters)", text: $model.habitTitle)
            DatePicker("Target date", selection: $model.countdownDate, in: ScriptWidgetRecordsModel.countdownDateRange, displayedComponents: .date)
                .environment(\.calendar, Calendar(identifier: .gregorian))
            Toggle("Repeat every year", isOn: $model.repeatYearly)
            if model.repeatYearly { Text("February 29 repeats only in leap years.").font(.caption).foregroundStyle(.secondary) }
            Picker("Accent", selection: $model.accent) {
                Text("Blue").tag("blue"); Text("Rose").tag("rose"); Text("Green").tag("green")
            }
        case .hydration:
            Stepper("Daily goal: \(model.goal) glasses", value: $model.goal, in: 1...32)
            Stepper("Glass size: \(model.glassML) mL", value: $model.glassML, in: 25...2000, step: 25)
        case .mood: TextField("Intention (up to 80 characters)", text: $model.intention)
        case .habitStreak: TextField("Habit name (up to 40 characters)", text: $model.habitTitle)
        case .habitHeatmap:
            LabeledContent("First habit") { TextField("Name", text: $model.readName).multilineTextAlignment(.trailing) }
            LabeledContent("Second habit") { TextField("Name", text: $model.runName).multilineTextAlignment(.trailing) }
            LabeledContent("Third habit") { TextField("Name", text: $model.meditateName).multilineTextAlignment(.trailing) }
        case .checklist:
            Text("One item per line, up to 8 unique items.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.itemsText).frame(minHeight: 100).accessibilityLabel("Checklist items, one per line")
        }
    }
}

private struct ScriptWidgetPickedPhoto: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let image = try ScriptWidgetPhotoPreparation.load(url: received.file)
            return Self(data: try ScriptWidgetPhotoPreparation.encode(image))
        }
    }
}

private struct ScriptWidgetPhotoDraft: Identifiable {
    let id = UUID()
    let image: CGImage
}

private struct ScriptWidgetPhotoThumbnail: View {
    let url: URL
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
        }
        .frame(width: 56, height: 56)
        .task(id: url) { image = try? await Task.detached { try ScriptWidgetPhotoPreparation.load(url: url, maximumPixelSize: 160) }.value }
    }
}

private struct ScriptWidgetPhotoConfigurationView: View {
    @ObservedObject var model: ScriptWidgetRecordsModel
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var importingFile = false
    @State private var isLoading = false
    @State private var draft: ScriptWidgetPhotoDraft?
    @State private var deleting: ImageModel?
    @State private var importError: String?
    var body: some View {
        TextField("Title (up to 40 characters)", text: $model.habitTitle)
        TextField("Caption (up to 80 characters)", text: $model.photoCaption)
        Picker("Layout", selection: $model.photoLayout) {
            Text("Single photo").tag("single"); Text("Two photos").tag("duo"); Text("Four-photo grid").tag("grid")
        }
        PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("Choose Photo…", systemImage: "photo") }
            .disabled(isLoading || model.photoAssets.count >= 12)
            .onChange(of: selectedPhoto) { item in
                guard let item else { return }
                Task {
                    isLoading = true; defer { isLoading = false; selectedPhoto = nil }
                    do {
                        guard let result = try await item.loadTransferable(type: ScriptWidgetPickedPhoto.self) else { throw ScriptWidgetRecordError.invalidData }
                        let prepared = try await Task.detached { try ScriptWidgetPhotoPreparation.load(data: result.data) }.value
                        draft = .init(image: prepared)
                    } catch { importError = "The photo could not be opened. Choose a still image up to 25 MiB, and download it from iCloud if needed." }
                }
            }
        Button("Import Photo File…") { importingFile = true }.disabled(isLoading || model.photoAssets.count >= 12)
            .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image]) { result in
                let url: URL
                do { url = try result.get() }
                catch { if (error as? CocoaError)?.code != .userCancelled { importError = "The selected photo file could not be opened." }; return }
                Task {
                    isLoading = true; defer { isLoading = false }
                    do {
                        let prepared = try await Task.detached {
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            return try ScriptWidgetPhotoPreparation.load(url: url)
                        }.value
                        draft = .init(image: prepared)
                    } catch { importError = "The image could not be opened. Choose an image file up to 25 MiB." }
                }
            }
            .sheet(item: $draft) { item in ScriptWidgetPhotoCropView(image: item.image, save: model.addPhoto) }
            .confirmationDialog("Delete this unused photo?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete Photo", role: .destructive) { if let deleting { model.deleteUnusedPhoto(deleting.name) }; deleting = nil }
                Button("Cancel", role: .cancel) { deleting = nil }
            }
        if isLoading { ProgressView("Preparing photo…") }
        if let importError { Text(importError).foregroundStyle(.red) }
        Text("Import up to 12 still photos and select up to 4. Crop and reorder your selection, then Save Configuration. Photo metadata is removed; originals in Photos or Files are kept.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        ForEach(Array(model.orderedPhotoAssets.enumerated()), id: \.element.id) { index, asset in
            HStack {
                ScriptWidgetPhotoThumbnail(url: asset.path)
                Toggle("Photo \(index + 1)", isOn: Binding(get: { model.photoNames.contains(asset.name) }, set: { enabled in
                    if enabled, model.photoNames.count < 4 { model.photoNames.append(asset.name) }
                    else if !enabled { model.photoNames.removeAll { $0 == asset.name } }
                })).disabled(!model.photoNames.contains(asset.name) && model.photoNames.count >= 4)
                if let position = model.photoNames.firstIndex(of: asset.name) {
                    Button { model.movePhoto(asset.name, offset: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(position == 0).accessibilityLabel("Move photo earlier")
                    Button { model.movePhoto(asset.name, offset: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(position == model.photoNames.count - 1).accessibilityLabel("Move photo later")
                    Text("Position \(position + 1)").monospacedDigit().font(.caption)
                } else if !model.protectedPhotoNames.contains(asset.name) {
                    Button(role: .destructive) { deleting = asset } label: { Image(systemName: "trash") }.accessibilityLabel("Delete unused photo")
                }
            }.buttonStyle(.borderless)
        }
        if model.photoNames.contains(where: { name in !model.photoAssets.contains { $0.name == name } }) {
            Text("Some selected photo files are unavailable. Reconnect iCloud storage, or select replacement photos.").foregroundStyle(.red)
            Button("Remove Unavailable Selections") { model.photoNames.removeAll { name in !model.photoAssets.contains { $0.name == name } } }
        }
        Text("Record backups include settings only. Export the widget package separately to keep its photo files.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct ScriptWidgetPhotoCropView: View {
    @Environment(\.dismiss) private var dismiss
    let image: CGImage
    let save: (CGImage) -> Bool
    @State private var zoom = 1.0
    @State private var horizontal = 0.5
    @State private var vertical = 0.5
    @State private var failed = false
    @State private var isSaving = false
    private var cropped: CGImage? { try? ScriptWidgetPhotoPreparation.crop(image, zoom: zoom, horizontal: horizontal, vertical: vertical) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let cropped { Image(decorative: cropped, scale: 1).resizable().scaledToFit().frame(maxHeight: 280) }
                LabeledContent("Zoom") { Slider(value: $zoom, in: 1...4).accessibilityLabel("Crop zoom") }
                LabeledContent("Horizontal") { Slider(value: $horizontal, in: 0...1).accessibilityLabel("Horizontal crop position") }
                LabeledContent("Vertical") { Slider(value: $vertical, in: 0...1).accessibilityLabel("Vertical crop position") }
                if failed { Text("The photo could not be saved. Close this sheet and check the widget's storage or remove an unused photo.").foregroundStyle(.red) }
                HStack {
                    Button("Cancel", role: .cancel) { dismiss() }.buttonStyle(.bordered)
                    Spacer()
                    Button("Add Photo") {
                        guard !isSaving else { return }
                        isSaving = true
                        if let cropped, save(cropped) { dismiss() }
                        else { failed = true; isSaving = false }
                    }
                    .buttonStyle(.borderedProminent).disabled(cropped == nil || isSaving)
                }
            }.padding(24)
            .navigationTitle("Crop Photo")
        }
#if os(macOS)
        .frame(minWidth: 480, minHeight: 500)
#endif
    }
}


struct ScriptWidgetWeatherCity: Identifiable {
    let name: String
    let latitude: Double
    let longitude: Double
    var id: String { "\(name):\(latitude):\(longitude)" }
}

private struct ScriptWidgetWeatherConfigurationView: View {
    @ObservedObject var model: ScriptWidgetRecordsModel
    var body: some View {
        Toggle("Use current location on iPhone", isOn: $model.weatherUseLocation)
        Text("When location is unavailable, the saved city is used. Weather requests send rounded coordinates to MET Norway.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        TextField("Find a city", text: $model.cityQuery)
        Button("Find City") { Task { await model.searchCities() } }.disabled(model.isSearchingCity || model.cityQuery.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
        if model.isSearchingCity { ProgressView("Finding cities…") }
        ForEach(model.cityResults) { city in
            Button { model.chooseCity(city) } label: { Text("\(city.name) · \(city.latitude, specifier: "%.2f"), \(city.longitude, specifier: "%.2f")") }
        }
        if let message = model.citySearchMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
        TextField("Saved city", text: $model.weatherCity)
        TextField("Latitude", value: $model.weatherLatitude, format: .number)
        TextField("Longitude", value: $model.weatherLongitude, format: .number)
        Picker("Temperature", selection: $model.weatherUnit) { Text("Celsius").tag("c"); Text("Fahrenheit").tag("f") }
        Link("Weather data: MET Norway · CC BY 4.0", destination: URL(string: "https://api.met.no/doc/License")!)
        Text("City search uses Apple Maps. You can also enter a label and coordinates directly. Allow location in the app's Settings to use your current position.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}


private struct ScriptWidgetLauncherConfigurationView: View {
    @ObservedObject var model: ScriptWidgetRecordsModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        LabeledContent("Launcher title") { TextField("Title",text:$model.habitTitle).multilineTextAlignment(.trailing) }
        Picker("Accent",selection:$model.accent) { Text("Blue").tag("blue");Text("Green").tag("green");Text("Rose").tag("rose") }
        ForEach($model.launcherItems) { $item in
            VStack(alignment:.leading,spacing:8) {
                LabeledContent("Button title") { TextField("Title",text:$item.title).multilineTextAlignment(.trailing) }
                Picker("Type",selection:$item.type) { Text("Web link").tag("web");Text("App link").tag("app");Text("Shortcut").tag("shortcut") }
                Picker("Icon",selection:$item.icon) {
                    ForEach(ScriptWidgetLauncherItem.icons,id:\.self) { name in Label(name,systemImage:name).tag(name) }
                }
                LabeledContent(item.type=="shortcut" ? "Shortcut name" : "URL") { TextField("Destination",text:$item.target).multilineTextAlignment(.trailing) }
                if item.type=="shortcut" { LabeledContent("Text input (optional)") { TextField("Text",text:$item.input).multilineTextAlignment(.trailing) } }
                HStack {
                    Button("Test Draft Link") {
                        guard let (captured,url)=model.prepareLauncherTest(id:item.id) else { return }
                        openURL(url) { accepted in
                            Task { @MainActor in model.finishLauncherTest(item:captured,accepted:accepted) }
                        }
                    }
                    Spacer()
                    Button("Remove",role:.destructive) { model.launcherItems.removeAll{$0.id==item.id} }.disabled(model.launcherItems.count<=1)
                }
                HStack {
                    Button("Move Up") { move(item.id,by:-1) }.disabled(model.launcherItems.first?.id==item.id)
                    Button("Move Down") { move(item.id,by:1) }.disabled(model.launcherItems.last?.id==item.id)
                }.font(.caption)
            }
        }
        Button("Add Link") {
            model.launcherItems.append(.init(id:UUID().uuidString.lowercased(),title:"New link",icon:"globe",type:"web",target:"https://example.com",input:""))
        }.disabled(model.launcherItems.count>=6)
        if let message=model.launcherTestMessage { Text(message).font(.caption).foregroundStyle(model.launcherTestFailed ? .red : .secondary) }
        Text("Testing opens the current draft without saving it. Shortcuts must already exist in your collection. A system-accepted URL does not confirm that the shortcut completed; check the target app. Widget links use the system directly.").font(.caption).foregroundStyle(.secondary)
    }

    private func move(_ id:String,by offset:Int) {
        guard let index=model.launcherItems.firstIndex(where:{$0.id==id}),model.launcherItems.indices.contains(index+offset) else { return }
        model.launcherItems.swapAt(index,index+offset)
    }
}

/// The same native catalog used by App Intents and Control Widgets. Listing never executes a script.
struct ScriptWidgetActionDirectoryView: View {
    private let catalog: () -> ScriptWidgetActionCatalog
    init(catalog: @escaping () -> ScriptWidgetActionCatalog = { .live }) { self.catalog=catalog }
    @State private var actions: [ResolvedScriptWidgetAction] = []
    @State private var controls: [String: [String]] = [:]

    var body: some View {
        List {
            Section {
                Text("Installed packages declare these actions. In Shortcuts, choose Run ScriptWidget Action and select one. Add a ScriptWidget button or toggle in Control Center to use compatible controls. Availability depends on the system version and platform.").font(.callout)
            }
            if actions.isEmpty {
                Text("No installed actions yet. Install a current habit, water, mood or checklist template, then refresh.").foregroundStyle(.secondary)
            }
            ForEach(actions,id:\.identifier) { resolved in
                VStack(alignment:.leading,spacing:4) {
                    Label(resolved.action.title,systemImage:resolved.action.systemImage)
                    Text(resolved.installationName).font(.caption).foregroundStyle(.secondary)
                    if let names=controls[resolved.identifier],!names.isEmpty { Text("Controls: "+names.joined(separator:", ")).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Widget Actions")
        .toolbar { Button { refresh() } label: { Label("Refresh",systemImage:"arrow.clockwise") } }
        .onAppear { refresh() }
    }

    private func refresh() {
        let catalog=self.catalog()
        actions=catalog.actions().sorted { ($0.installationName,$0.action.title,$0.identifier)<($1.installationName,$1.action.title,$1.identifier) }
        var labels:[String:[String]]=[:]
        for type in [WidgetPackageControlType.button,.toggle] {
            for (resolved,control) in catalog.controls(type:type) { labels[resolved.identifier,default:[]].append(control.title) }
        }
        controls=labels
    }
}


private struct ScriptWidgetWallpaperPickedImage: Transferable {
    let image:CGImage
    static var transferRepresentation:some TransferRepresentation {
        FileRepresentation(importedContentType:.image) { received in
            let image=try ScriptWidgetPhotoPreparation.load(url:received.file,maximumPixelSize:3072)
            return Self(image:image)
        }
    }
}

private struct ScriptWidgetWallpaperConfigurationView:View {
    @ObservedObject var model:ScriptWidgetRecordsModel
    @Environment(\.colorScheme) private var scheme
    @State private var selected:PhotosPickerItem?
    @State private var importing=false
    @State private var loading=false
    @State private var draft:ScriptWidgetPhotoDraft?
    @State private var errorMessage:String?
    @State private var deleting:ImageModel?
    var body:some View {
        Text("Match a crop from your own wallpaper or an empty Home Screen screenshot. Calibrate each size and position in the next step. The source screenshot is not saved in the package.").font(.caption).foregroundStyle(.secondary)
        TextField("Title (optional, up to 40 characters)",text:$model.habitTitle)
        TextField("Caption (optional, up to 80 characters)",text:$model.photoCaption)
        Picker("Content",selection:$model.wallpaperContent) { Text("Background only").tag("none");Text("Title and caption").tag("text");Text("Date").tag("date") }
        Picker("Text color",selection:$model.wallpaperInk) { Text("Follow appearance").tag("adaptive");Text("Light").tag("light");Text("Dark").tag("dark") }
        PhotosPicker(selection:$selected,matching:.images) { Label("Choose Screenshot or Wallpaper…",systemImage:"photo") }
            .disabled(loading || model.wallpaperAssets.count>=12)
            .onChange(of:selected) { item in
                guard let item else { return }
                Task {
                    loading=true;defer{loading=false;selected=nil}
                    do {
                        guard let loaded=try await item.loadTransferable(type:ScriptWidgetWallpaperPickedImage.self) else { throw ScriptWidgetRecordError.invalidData }
                        draft = .init(image:loaded.image)
                    } catch { errorMessage="The image could not be opened. Choose an image up to 25 MiB, downloaded from iCloud if needed." }
                }
            }
        Button("Import Image File…") { importing=true }.disabled(loading || model.wallpaperAssets.count>=12)
            .fileImporter(isPresented:$importing,allowedContentTypes:[.image]) { result in
                let url:URL
                do { url=try result.get() } catch { if (error as? CocoaError)?.code != .userCancelled { errorMessage="The image file could not be opened." };return }
                Task {
                    loading=true;defer{loading=false}
                    do {
                        let image=try await Task.detached {
                            let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
                            return try ScriptWidgetPhotoPreparation.load(url:url,maximumPixelSize:3072)
                        }.value
                        draft = .init(image:image)
                    } catch { errorMessage="The image could not be opened. Choose a still image up to 25 MiB." }
                }
            }
            .sheet(item:$draft) { item in ScriptWidgetWallpaperCropView(image:item.image,initialAppearance:scheme == .dark ? "dark" : "light",save:model.addWallpaperCrop) }
            .confirmationDialog("Delete this unused crop?",isPresented:Binding(get:{deleting != nil},set:{if !$0{deleting=nil}}),titleVisibility:.visible) {
                Button("Delete Crop",role:.destructive) { if let deleting{model.deleteUnusedWallpaper(deleting.name)};deleting=nil }
                Button("Cancel",role:.cancel){deleting=nil}
            }
        if loading { ProgressView("Preparing image…") }
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        ForEach(model.wallpaperBackgrounds) { asset in
            HStack {
                if let image=model.wallpaperAssets.first(where:{$0.name==asset.image}) { ScriptWidgetPhotoThumbnail(url:image.path) }
                VStack(alignment:.leading) { Text(asset.label);Text(ScriptWidgetWallpaperAsset.familyTitle(asset.family)+" · "+asset.appearance.capitalized).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { model.wallpaperBackgrounds.removeAll{$0.id==asset.id} } label:{Image(systemName:"minus.circle")}.accessibilityLabel("Remove \(asset.family) \(asset.appearance) selection")
            }.buttonStyle(.borderless)
        }
        if model.wallpaperBackgrounds.contains(where:{asset in !model.wallpaperAssets.contains{$0.name==asset.image}}) { Text("Some selected crop files are unavailable. Restore the package resources or import replacement crops.").foregroundStyle(.red) }
        ForEach(model.wallpaperAssets.filter{!model.protectedWallpaperNames.contains($0.name)}) { asset in
            HStack {
                ScriptWidgetPhotoThumbnail(url:asset.path);Text("Unused crop").font(.caption);Spacer()
                Button(role:.destructive){deleting=asset}label:{Image(systemName:"trash")}.accessibilityLabel("Delete unused wallpaper crop")
            }.buttonStyle(.borderless)
        }
        Text("Save Configuration after adding or removing selections. Keep at most 12 crops (10 size/appearance selections plus spare crops). Record backups contain settings; export the widget package to retain images.").font(.caption).foregroundStyle(.secondary)
        Text("Use the same Home Screen position, orientation, wallpaper and appearance as your reference. System tinting and glass styles can change the result. This is a screenshot match, not automatic transparency or a wallpaper-setting permission.").font(.caption).foregroundStyle(.secondary)
    }
}

private struct ScriptWidgetWallpaperPNGDocument:FileDocument {
    static var readableContentTypes:[UTType]{[.png]}
    var data:Data
    init(data:Data){self.data=data}
    init(configuration:ReadConfiguration)throws{data=configuration.file.regularFileContents ?? Data()}
    func fileWrapper(configuration:WriteConfiguration)throws->FileWrapper{FileWrapper(regularFileWithContents:data)}
}

struct ScriptWidgetWallpaperCropView:View {
    @Environment(\.dismiss) private var dismiss
    let image:CGImage
    let save:(CGImage,String,String,String)->Bool
    @State private var crop:ScriptWidgetWallpaperCrop
    @State private var family="medium"
    @State private var appearance:String
    @State private var label="My position"
    @State private var dragStart:ScriptWidgetWallpaperCrop?
    @State private var busy=false
    @State private var failed=false
    @State private var exporting=false
    @State private var document:ScriptWidgetWallpaperPNGDocument?
    init(image:CGImage,initialAppearance:String="light",save:@escaping(CGImage,String,String,String)->Bool) {
        self.image=image;self.save=save
        _crop=State(initialValue:.initial(family:"medium",imageWidth:image.width,imageHeight:image.height))
        _appearance=State(initialValue:initialAppearance=="dark" ? "dark":"light")
    }
    private var preview:CGImage? { guard let rect=try? crop.rectangle(imageWidth:image.width,imageHeight:image.height) else {return nil};return image.cropping(to:rect) }
    private var validLabel:Bool { ScriptWidgetWallpaperAsset.validLabel(label) }
    private func field(_ keyPath:WritableKeyPath<ScriptWidgetWallpaperCrop,Int>)->Binding<Int> {
        Binding(get:{crop[keyPath:keyPath]},set:{value in
            crop[keyPath:keyPath]=value;crop.width=min(image.width,max(1,crop.width));crop.height=min(image.height,max(1,crop.height))
            crop.x=min(image.width-crop.width,max(0,crop.x));crop.y=min(image.height-crop.height,max(0,crop.y))
        })
    }
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    Text("1 · Choose size and appearance").font(.headline)
                    Picker("Widget size",selection:$family){ForEach(ScriptWidgetWallpaperAsset.families,id:\.self){Text(ScriptWidgetWallpaperAsset.familyTitle($0)).tag($0)}}
                        .onChange(of:family){value in crop = .initial(family:value,imageWidth:image.width,imageHeight:image.height)}
                    Picker("Appearance",selection:$appearance){Text("Light").tag("light");Text("Dark").tag("dark")}.pickerStyle(.segmented)
                    TextField("Position label (up to 30 characters)",text:$label)
                    Text("2 · Calibrate the outline").font(.headline)
                    Text("Drag the outline, then adjust exact pixels. Size presets are starting shapes; align the rectangle with the widget area in your reference. Imported images are bounded to 3072 pixels on the longest edge.").font(.caption).foregroundStyle(.secondary)
                    GeometryReader { proxy in
                        let scale=max(0.001,min(proxy.size.width/CGFloat(image.width),proxy.size.height/CGFloat(image.height)))
                        ZStack(alignment:.topLeading) {
                            Image(decorative:image,scale:1).resizable().frame(width:CGFloat(image.width)*scale,height:CGFloat(image.height)*scale)
                            Rectangle().fill(Color.blue.opacity(0.13)).overlay(Rectangle().stroke(Color.blue,lineWidth:2))
                                .frame(width:CGFloat(crop.width)*scale,height:CGFloat(crop.height)*scale)
                                .position(x:CGFloat(crop.x)*scale+CGFloat(crop.width)*scale/2,y:CGFloat(crop.y)*scale+CGFloat(crop.height)*scale/2)
                                .gesture(DragGesture().onChanged{value in
                                    let start=dragStart ?? crop;if dragStart==nil{dragStart=start}
                                    crop.x=min(image.width-crop.width,max(0,start.x+Int((value.translation.width/scale).rounded())))
                                    crop.y=min(image.height-crop.height,max(0,start.y+Int((value.translation.height/scale).rounded())))
                                }.onEnded{_ in dragStart=nil})
                        }.frame(width:CGFloat(image.width)*scale,height:CGFloat(image.height)*scale).frame(maxWidth:.infinity,maxHeight:.infinity)
                    }.frame(height:300).accessibilityLabel("Screenshot with movable crop outline; pixel fields also adjust the crop")
                    Text("Working image: \(image.width) × \(image.height) pixels").font(.caption).monospacedDigit()
                    HStack { LabeledContent("Left"){TextField("X",value:field(\.x),format:.number)};LabeledContent("Top"){TextField("Y",value:field(\.y),format:.number)} }
                    HStack { LabeledContent("Width"){TextField("Width",value:field(\.width),format:.number)};LabeledContent("Height"){TextField("Height",value:field(\.height),format:.number)} }
                    Button("Reset Outline"){crop = .initial(family:family,imageWidth:image.width,imageHeight:image.height)}
                    Text("3 · Preview and add crop").font(.headline)
                    if let preview { Image(decorative:preview,scale:1).resizable().scaledToFit().frame(maxHeight:180).clipShape(RoundedRectangle(cornerRadius:16)) }
                    Text("Only this crop is saved, at up to 1024 pixels on its longest edge. Match this widget’s actual position and Home Screen style after installing it.").font(.caption).foregroundStyle(.secondary)
                    if failed { Text("The crop could not be saved or exported. Check storage, image limits and position label.").foregroundStyle(.red) }
                    HStack {
                        Button("Cancel",role:.cancel){dismiss()}
                        Button("Export Crop PNG…"){
                            busy=true;let selection=crop
                            Task {
                                do { let data=try await Task.detached{try ScriptWidgetPhotoPreparation.encode(selection.cropped(image))}.value;document = .init(data:data);exporting=true }
                                catch { failed=true };busy=false
                            }
                        }
                        Spacer()
                        Button("Add Crop") {
                            busy=true;let selection=crop,selectedFamily=family,selectedAppearance=appearance,selectedLabel=label
                            Task {
                                do {let result=try await Task.detached{try selection.cropped(image)}.value;if save(result,selectedFamily,selectedAppearance,selectedLabel){dismiss()}else{failed=true}}
                                catch{failed=true};busy=false
                            }
                        }.buttonStyle(.borderedProminent).disabled(!validLabel)
                    }.disabled(busy || preview==nil)
                    if !validLabel { Text("Enter a position label of 1–30 characters without control characters.").font(.caption).foregroundStyle(.red) }
                    if busy { ProgressView("Preparing crop…") }
                }.padding(20).disabled(busy)
            }.navigationTitle("Match Background")
            .interactiveDismissDisabled(busy)
            .fileExporter(isPresented:$exporting,document:document,contentType:.png,defaultFilename:"widget-background") { result in if case .failure(let error)=result,(error as? CocoaError)?.code != .userCancelled{failed=true} }
        }
        #if os(macOS)
        .frame(minWidth:560,minHeight:700)
        #endif
    }
}
