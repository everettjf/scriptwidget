import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DesktopToolsView: View {
    @Bindable var navigation: DesktopToolsNavigation
    @AppStorage("desktopTools.frosted") private var frosted = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Picker("Desktop tool", selection: $navigation.destination) {
                ForEach(DesktopToolDestination.allCases) { destination in
                    Text(destination.title).tag(destination)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ZStack(alignment: .topLeading) {
                DesktopLauncherView().toolVisibility(navigation.destination == .launcher)
                if navigation.destination == .system { DesktopSystemView() }
                DesktopAudioView().toolVisibility(navigation.destination == .music)
                DesktopTranslationView().toolVisibility(navigation.destination == .translation)
                if navigation.destination == .appearance { appearance }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(22)
        .padding(.top, 26)
        .background {
            if frosted && !reduceTransparency {
                DesktopBackdrop().ignoresSafeArea()
            } else {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            }
        }
    }

    private var appearance: some View {
        Form {
            Toggle("Frosted background", isOn: $frosted)
            Toggle("Show floating pet", isOn: $navigation.petVisible)
                .onChange(of: navigation.petVisible) { _, visible in
                    DesktopToolsWindow.shared.setPetVisible(visible)
                }
            Text("Drag the pet by its empty border. Click the pet to interact with it.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

private extension View {
    func toolVisibility(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .disabled(!visible)
    }
}

private struct DesktopLauncherView: View {
    @AppStorage("desktopTools.launcherItems") private var encodedItems = Data()
    @State private var icons: [UUID: NSImage] = [:]
    @State private var error: String?
    @State private var editing = false

    private var items: [DesktopLaunchItem] {
        guard encodedItems.count <= 1_048_576,
              let items = try? JSONDecoder().decode([DesktopLaunchItem].self, from: encodedItems),
              items.count <= 12, Set(items.map(\.id)).count == items.count else { return [] }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Button("Add App", systemImage: "plus.app") { choose(app: true) }
                Button("Add Folder", systemImage: "folder.badge.plus") { choose(app: false) }
                Spacer()
                Button(editing ? "Done" : "Edit") { editing.toggle() }
                    .disabled(items.isEmpty)
            }
            if items.isEmpty {
                ContentUnavailableView("No shortcuts", systemImage: "square.grid.3x2",
                                       description: Text("Choose the apps and folders you want to open from this grid."))
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 4), spacing: 9) {
                        ForEach(items) { item in
                            Button {
                                if editing { save(items.filter { $0.id != item.id }) }
                                else { open(item) }
                            } label: {
                                VStack(spacing: 5) {
                                    if editing {
                                        Image(systemName: "minus.circle.fill").font(.system(size: 40))
                                    } else if let icon = icons[item.id] {
                                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 42, height: 42)
                                    } else {
                                        Image(systemName: "questionmark.folder").font(.system(size: 36))
                                    }
                                    Text(item.name).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, minHeight: 82)
                                .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(editing ? "Remove \(item.name)" : "Open \(item.name)")
                            .help(item.name)
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .task(id: encodedItems) {
            var next: [UUID: NSImage] = [:]
            for item in items {
                guard let url = try? item.resolve(), url.startAccessingSecurityScopedResource() else { continue }
                next[item.id] = NSWorkspace.shared.icon(forFile: url.path)
                url.stopAccessingSecurityScopedResource()
            }
            icons = next
        }
    }

    private func choose(app: Bool) {
        guard items.count < 12 else {
            error = "The grid holds 12 shortcuts. Remove one before adding another."
            return
        }
        guard let parent = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = !app
        panel.canChooseFiles = app
        panel.treatsFilePackagesAsDirectories = false
        if app { panel.allowedContentTypes = [.applicationBundle] }
        panel.beginSheetModal(for: parent) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let item = try DesktopLaunchItem(url: url)
                save(items + [item])
            } catch {
                self.error = "Couldn’t save access to that item."
            }
        }
    }

    private func save(_ items: [DesktopLaunchItem]) {
        guard let data = try? JSONEncoder().encode(items), data.count <= 1_048_576 else {
            error = "Couldn’t save the launcher grid."
            return
        }
        encodedItems = data
        error = nil
        if items.isEmpty { editing = false }
    }

    private func open(_ item: DesktopLaunchItem) {
        guard let url = try? item.resolve(), url.startAccessingSecurityScopedResource() else {
            error = "Access expired. Remove this shortcut and choose the item again."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        error = NSWorkspace.shared.open(url) ? nil : "Couldn’t open this item."
    }
}

private struct DesktopSystemView: View {
    @State private var cpu: Double?
    @State private var memory: (used: UInt64, total: UInt64)?
    @State private var rows: [DesktopProcessReading] = []
    @State private var usage: [pid_t: Double] = [:]
    @State private var rankByCPU = true

    private var ranked: [DesktopProcessReading] {
        Array(rows.sorted { left, right in
            if rankByCPU {
                let first = usage[left.id] ?? -1
                let second = usage[right.id] ?? -1
                if first != second { return first > second }
            } else if left.residentBytes != right.residentBytes {
                return left.residentBytes > right.residentBytes
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                meter("CPU", fraction: cpu)
                meter("Memory", fraction: memory.flatMap { $0.total > 0 ? Double($0.used) / Double($0.total) : nil })
            }
            Picker("Rank apps by", selection: $rankByCPU) {
                Text("CPU").tag(true)
                Text("Resident Memory").tag(false)
            }
            .pickerStyle(.segmented)

            if rows.isEmpty {
                ContentUnavailableView("Waiting for app readings", systemImage: "cpu",
                                       description: Text("macOS may limit readings for some apps."))
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(ranked) { row in
                            HStack {
                                Text(row.name).lineLimit(1)
                                Spacer()
                                Text(usage[row.id].map { String(format: "%.1f%%", $0) } ?? "—")
                                    .frame(width: 72, alignment: .trailing)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: row.residentBytes), countStyle: .memory))
                                    .frame(width: 88, alignment: .trailing)
                            }
                            .font(.callout.monospacedDigit())
                            Divider()
                        }
                    }
                }
            }
            Text("Running apps with readings available. 100% per app represents one CPU core.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await sampleWhileVisible() }
    }

    private func meter(_ name: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                .font(.title.monospacedDigit())
            if let fraction { ProgressView(value: fraction).accessibilityLabel(name) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 12))
    }

    private func sampleWhileVisible() async {
        var previousCPU: DesktopCPUReading?
        var previous: [pid_t: DesktopProcessReading] = [:]
        var previousTime = mach_absolute_time()
        while !Task.isCancelled {
            let apps = NSWorkspace.shared.runningApplications.lazy
                .filter { $0.activationPolicy == .regular && !$0.isTerminated }
                .prefix(128)
                .map { ($0.processIdentifier, $0.localizedName ?? "Application") }
            let currentTime = mach_absolute_time()
            let currentCPU = DesktopSystemSampler.cpu()
            cpu = previousCPU.flatMap { currentCPU?.fraction(since: $0) }
            memory = DesktopSystemSampler.memory()
            var next: [pid_t: DesktopProcessReading] = [:]
            var nextUsage: [pid_t: Double] = [:]
            for (pid, name) in apps {
                guard let row = DesktopSystemSampler.process(id: pid, name: name) else { continue }
                next[pid] = row
                nextUsage[pid] = row.cpuPercent(since: previous[pid], elapsedTicks: currentTime - previousTime)
            }
            rows = Array(next.values)
            usage = nextUsage
            previousCPU = currentCPU
            previous = next
            previousTime = currentTime
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
