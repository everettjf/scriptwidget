import SwiftUI

struct WebStudioServerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var server = WebStudioServer.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    connectionCard
                    if let model = previewModel, let relativePath = server.previewRelativePath,
                       let fileURL = model.package.resolvedPackageURL(relativePath: relativePath) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Device Preview").font(.headline)
                            WebStudioPreview(model: model, fileURL: fileURL, revision: server.previewRevision)
                                .frame(minHeight: 440)
                                .clipShape(.rect(cornerRadius: 16))
                        }
                    } else if server.isRunning {
                        VStack(spacing: 12) {
                            Image(systemName: "laptopcomputer.and.iphone")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("Waiting for Web Studio").font(.headline)
                            Text("Open a widget in the browser to start its native preview.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 260)
                    }
                }
                .padding()
            }
            .navigationTitle("Web Studio")
            .onChange(of: scenePhase) { phase in
                if phase != .active { server.stop() }
            }
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(server.isRunning ? "Web Studio is running" : "Edit from any computer", systemImage: server.isRunning ? "wifi" : "laptopcomputer")
                .font(.title3.weight(.semibold))
            if server.isRunning {
                Text("Keep this screen open, then visit this address from a computer on the same network:")
                    .foregroundStyle(.secondary)
                ForEach(server.displayURLs, id: \.self) { url in
                    Text(url).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                LabeledContent("Pairing code") {
                    Text(server.pairingCode).font(.system(.title2, design: .monospaced).weight(.bold)).textSelection(.enabled)
                }
                LabeledContent("Connected browsers", value: "\(server.connectedClientCount)")
                Button("Stop Web Studio", role: .destructive) { server.stop() }
                    .buttonStyle(.bordered)
            } else {
                Text("Your browser edits code. This iPhone or iPad runs the native Widget preview.")
                    .foregroundStyle(.secondary)
                Button("Start Web Studio", systemImage: "play.fill") { server.start() }
                    .buttonStyle(.borderedProminent)
            }
            if let error = server.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private var previewModel: ScriptModel? {
        guard let name = server.previewPackageName else { return nil }
        return sharedScriptManager.listScripts().first { $0.name == name }
    }
}

private struct WebStudioPreview: View {
    let model: ScriptModel
    let revision: Int
    @State private var fileURL: URL

    init(model: ScriptModel, fileURL: URL, revision: Int) {
        self.model = model
        self.revision = revision
        _fileURL = State(initialValue: fileURL)
    }

    var body: some View {
        ScriptCodePreviewView(model: model, filePath: $fileURL, showsCloseButton: false)
            .id(revision)
    }
}
