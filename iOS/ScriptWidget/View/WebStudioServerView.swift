import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

struct WebStudioServerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @ObservedObject private var server = WebStudioServer.shared
    @State private var copiedValue: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    connectionCard
                    if server.isRunning { diagnosticsCard }
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
                if let primaryURL = server.displayURLs.first {
                    HStack(alignment: .top, spacing: 16) {
                        WebStudioQRCodeView(value: primaryURL)
                            .frame(width: 132, height: 132)
                            .accessibilityLabel("QR code for Web Studio address")
                        VStack(alignment: .leading, spacing: 8) {
                            Text(primaryURL)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Button(copiedValue == primaryURL ? "Copied" : "Copy Address", systemImage: copiedValue == primaryURL ? "checkmark" : "doc.on.doc") {
                                copy(primaryURL)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                ForEach(server.displayURLs.dropFirst(), id: \.self) { url in
                    Button {
                        copy(url)
                    } label: {
                        Label(url, systemImage: copiedValue == url ? "checkmark" : "doc.on.doc")
                            .font(.system(.callout, design: .monospaced))
                    }
                }
                LabeledContent("Pairing code") {
                    Button {
                        copy(server.pairingCode)
                    } label: {
                        Label(server.pairingCode, systemImage: copiedValue == server.pairingCode ? "checkmark" : "doc.on.doc")
                            .font(.system(.title2, design: .monospaced).weight(.bold))
                    }
                    .accessibilityHint("Copies the pairing code")
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
            if let hint = server.connectionHint {
                Text(hint).font(.callout).foregroundStyle(.secondary)
                Button("Open Local Network Settings", systemImage: "gear") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private var diagnosticsCard: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("If the computer cannot connect, confirm both devices use the same Wi-Fi, turn off VPN, and avoid guest networks that isolate clients.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open Settings", systemImage: "gear") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    ShareLink(item: server.diagnosticReport) {
                        Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                    }
                }
                if !server.logs.isEmpty {
                    Divider()
                    ForEach(server.logs.suffix(12)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message).font(.caption.monospaced())
                            Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            Label("Connection Help & Diagnostics", systemImage: "stethoscope")
                .font(.headline)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private func copy(_ value: String) {
        UIPasteboard.general.string = value
        copiedValue = value
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedValue == value { copiedValue = nil }
        }
    }

    private var previewModel: ScriptModel? {
        guard let name = server.previewPackageName else { return nil }
        return sharedScriptManager.listScripts().first { $0.name == name }
    }
}

private struct WebStudioQRCodeView: View {
    let value: String

    var body: some View {
        if let image = qrImage {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else {
            Image(systemName: "qrcode")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    private var qrImage: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext(options: nil).createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
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
            .background(WebStudioPreviewSnapshotCapture(revision: revision))
    }
}

private struct WebStudioPreviewSnapshotCapture: UIViewRepresentable {
    let revision: Int

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let revision = revision
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak view] in
            guard let target = view?.superview, target.bounds.width > 1, target.bounds.height > 1 else { return }
            let format = UIGraphicsImageRendererFormat()
            format.scale = min(UIScreen.main.scale, 2)
            let renderer = UIGraphicsImageRenderer(bounds: target.bounds, format: format)
            let image = renderer.image { context in
                target.layer.render(in: context.cgContext)
            }
            guard let data = image.pngData() else { return }
            WebStudioServer.shared.updatePreviewSnapshot(data, revision: revision)
        }
    }
}
