import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @State private var isImporting = false
    @State private var importSucceeded = false
    @State private var showFilePicker = false
    @State private var progress: Float = 0
    @State private var statusMessage = ""
    @State private var logMessages: [String] = []
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Label("Restore your widget library", systemImage: "archivebox")
                    .font(.title3.bold())
                Text("Choose a ScriptWidget ZIP archive. Import activity and any conflicts will be shown below.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    showFilePicker = true
                } label: {
                    Label(importSucceeded ? "Import Complete" : "Choose Archive", systemImage: importSucceeded ? "checkmark.circle.fill" : "doc.zipper")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isImporting || importSucceeded)

                ProgressView(value: progress)
                    .tint(.indigo)

                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            List {
                Section("Activity") {
                    if logMessages.isEmpty {
                        Label("Import activity will appear here", systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(logMessages, id: \.self) { message in
                        Label(message, systemImage: "checkmark.circle")
                            .font(.caption)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Import Scripts")
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let files):
                if let file = files.first {
                    importFile(file)
                }
            case .failure(let error):
                print("Error selecting file: \(error.localizedDescription)")
            }
        }
    }
    
    private func importFile(_ file: URL) {
        isImporting = true
        importSucceeded = false
        progress = 0
        statusMessage = "Starting import..."
        logMessages.removeAll()
        
        Task {
            do {
                try await ImportManager.importScripts(from: file) { currentProgress, message in
                    DispatchQueue.main.async {
                        self.progress = currentProgress
                        self.statusMessage = message
                        self.logMessages.insert(message, at: 0)
                    }
                }
                
                DispatchQueue.main.async {
                    self.isImporting = false
                    self.importSucceeded = true
                    self.statusMessage = "Import completed successfully"
                    self.logMessages.insert("Import completed successfully", at: 0)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isImporting = false
                    self.importSucceeded = false
                    self.statusMessage = "Error: \(error.localizedDescription)"
                    self.logMessages.insert("Error: \(error.localizedDescription)", at: 0)
                }
            }
        }
    }
}

struct ImportView_Previews: PreviewProvider {
    static var previews: some View {
        ImportView()
    }
}
