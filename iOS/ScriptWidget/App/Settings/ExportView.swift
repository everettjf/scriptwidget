import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    @State private var isExporting = false
    @State private var exportSucceeded = false
    @State private var progress: Float = 0
    @State private var statusMessage = ""
    @State private var logMessages: [String] = []
    @State private var exportedFileURL: URL?
    @State private var showShareSheet = false
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Label("Back up your widget library", systemImage: "archivebox")
                    .font(.title3.bold())
                Text("Package every script and its assets into one portable ZIP archive for sharing or safekeeping.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    startExport()
                } label: {
                    Label(exportSucceeded ? "Export Complete" : "Create Archive", systemImage: exportSucceeded ? "checkmark.circle.fill" : "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isExporting || exportSucceeded)

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
                        Label("Export activity will appear here", systemImage: "clock")
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
        .navigationTitle("Export Scripts")
        .sheet(isPresented: $showShareSheet, content: {
            if let fileURL = exportedFileURL {
                ActivityViewController(activityItems: [fileURL])
            }
        })
    }
    
    private func startExport() {
        isExporting = true
        exportSucceeded = false
        progress = 0
        statusMessage = "Starting export..."
        logMessages.removeAll() // Clear previous log messages
        
        Task {
            do {
                let zipFileURL = try await ExportManager.exportAllScripts { currentProgress, message in
                    DispatchQueue.main.async {
                        self.progress = currentProgress
                        self.statusMessage = message
                        self.logMessages.insert(message, at: 0) // Insert new message at the beginning
                    }
                }
                
                DispatchQueue.main.async {
                    self.exportedFileURL = zipFileURL
                    self.showShareSheet = true
                    self.isExporting = false
                    self.exportSucceeded = true
                    self.statusMessage = "Export completed successfully"
                    self.logMessages.insert("Export completed successfully", at: 0) // Insert final message at the beginning
                }
            } catch {
                DispatchQueue.main.async {
                    self.isExporting = false
                    self.exportSucceeded = false
                    self.statusMessage = "Error: \(error.localizedDescription)"
                    self.logMessages.insert("Error: \(error.localizedDescription)", at: 0) // Insert error message at the beginning
                }
            }
        }
    }
}

struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ExportView_Previews: PreviewProvider {
    static var previews: some View {
        ExportView()
    }
}
