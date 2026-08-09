//
//  FileListView.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/2/19.
//

import SwiftUI
import UniformTypeIdentifiers

struct ProjectFileNode: Identifiable, Hashable {
    let name: String
    let relativePath: String
    let path: URL
    let children: [ProjectFileNode]?

    var id: String { relativePath }
    var isDirectory: Bool { children != nil }
}

class FileListDataObject: ObservableObject {
    @Published var files: [FileModel] = []
    @Published var nodes: [ProjectFileNode] = []
    
    let scriptModel: ScriptModel
    init(scriptModel: ScriptModel) {
        self.scriptModel = scriptModel
        
        self.reload()
        self.addObserver()
    }
    
    func reload() {
        scriptModel.package.updateFiles()
        self.files = scriptModel.package.listFiles()
        self.nodes = Self.loadNodes(at: scriptModel.package.path, relativeTo: scriptModel.package.path)
    }
    
    
    func addObserver() {
        NotificationCenter.default.addObserver(forName: ImageDataObject.refreshNotification, object: nil, queue: OperationQueue.main) { (noti) in
            self.reload()
        }
    }

    private static func loadNodes(at directory: URL, relativeTo root: URL) -> [ProjectFileNode] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard url.lastPathComponent != "__Build" else { return nil }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard url.path.hasPrefix(rootPrefix) else { return nil }
            let relativePath = String(url.path.dropFirst(rootPrefix.count))
            return ProjectFileNode(
                name: url.lastPathComponent,
                relativePath: relativePath,
                path: url,
                children: isDirectory ? loadNodes(at: url, relativeTo: root) : nil
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct FileListView: View {
    @StateObject private var data: FileListDataObject
    @Binding private var selectedFilePath: String
    @State private var showingImporter = false
    @State private var showingNewFilePrompt = false
    @State private var newFileName = ""
    @State private var errorMessage: String?
    
    init(scriptModel: ScriptModel, selectedFilePath: Binding<String>) {
        _data = StateObject(wrappedValue: FileListDataObject(scriptModel: scriptModel))
        _selectedFilePath = selectedFilePath
    }
    
    var body: some View {
        VStack(spacing: 0) {
            projectHeader
            Divider()
            List {
                if data.nodes.isEmpty {
                    ContentUnavailableView("Empty Project", systemImage: "folder", description: Text("Create or import a file to get started."))
                } else {
                    OutlineGroup(data.nodes, children: \.children) { node in
                        projectRow(node)
                    }
                }
            }
            .listStyle(.sidebar)
            .refreshable { data.reload() }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data, .image], allowsMultipleSelection: true) {
            importFiles($0)
        }
        .alert("New Project File", isPresented: $showingNewFilePrompt) {
            TextField("helpers.js", text: $newFileName)
            Button("Create", action: createFile)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Create a JSX, JavaScript, JSON, text, Markdown, or CSS file in the widget package.")
        }
        .alert("Project Operation Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var projectHeader: some View {
        HStack(spacing: 8) {
            Label("Project", systemImage: "folder")
                .font(.headline)
            Spacer()
            Menu {
                Button("New File…", systemImage: "doc.badge.plus") {
                    newFileName = ""
                    showingNewFilePrompt = true
                }
                Button("Import Files…", systemImage: "square.and.arrow.down") {
                    showingImporter = true
                }
                Divider()
                Button("Reveal in Finder", systemImage: "finder") {
                    MacKitUtil.revealInFinder(data.scriptModel.package.path.path)
                }
                Button("Refresh", systemImage: "arrow.clockwise") { data.reload() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .help("Add project file")
        }
        .padding(12)
        .background(.bar)
    }

    @ViewBuilder
    private func projectRow(_ node: ProjectFileNode) -> some View {
        if node.isDirectory {
            Label(node.name, systemImage: "folder")
                .fontWeight(.medium)
        } else {
            Button {
                guard isEditableTextFile(node.path) else { return }
                selectedFilePath = node.relativePath
            } label: {
                Label(node.name, systemImage: iconName(for: node.path))
                    .foregroundStyle(node.relativePath == selectedFilePath ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
            .disabled(!isEditableTextFile(node.path))
            .contextMenu {
                Button("Reveal in Finder", systemImage: "finder") {
                    MacKitUtil.revealInFinder(node.path.path)
                }
            }
        }
    }

    private func isEditableTextFile(_ url: URL) -> Bool {
        ["jsx", "js", "json", "txt", "md", "css"].contains(url.pathExtension.lowercased())
    }

    private func iconName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jsx", "js": return "curlybraces"
        case "json": return "list.bullet.rectangle"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        default: return "doc.text"
        }
    }

    private func createFile() {
        let filename = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty, filename == URL(fileURLWithPath: filename).lastPathComponent else {
            errorMessage = "Enter a filename without folders or path traversal."
            return
        }
        let allowed = ["jsx", "js", "json", "txt", "md", "css"]
        guard allowed.contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) else {
            errorMessage = "Use a supported text extension: jsx, js, json, txt, md, or css."
            return
        }
        guard !data.scriptModel.package.isFileExist(relativePath: filename) else {
            errorMessage = "A file named \(filename) already exists."
            return
        }
        let initialContent = filename.hasSuffix(".json") ? "{}\n" : ""
        let result = data.scriptModel.package.writeFile(relativePath: filename, content: initialContent)
        guard result.0 else {
            errorMessage = result.1
            return
        }
        data.reload()
        selectedFilePath = filename
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            return
        }
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let imported = data.scriptModel.package.importProjectFile(from: url)
            if !imported.0 {
                errorMessage = imported.1
                break
            }
        }
        data.reload()
    }
}

struct FileListView_Previews: PreviewProvider {
    static var previews: some View {
        FileListView(scriptModel: globalScriptModel, selectedFilePath: .constant("main.jsx"))
    }
}
