import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class DesktopAudioPlayer {
    private var player: AVAudioPlayer?
    private var scopedURL: URL?
    private var queue: [URL] = []
    private var index = 0

    var title = ""
    var artist = ""
    var artwork: NSImage?
    var error: String?
    var isPlaying = false
    private(set) var trackURL: URL?
    var hasQueue: Bool { !queue.isEmpty }

    func load(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        queue = Array(urls.prefix(30))
        index = 0
        openTrack(autoplay: false)
    }

    func execute(_ command: DesktopMediaCommand) {
        guard !queue.isEmpty else { return }
        error = nil
        switch command {
        case .previous, .next:
            let offset = command == .next ? 1 : -1
            index = (index + offset + queue.count) % queue.count
            openTrack(autoplay: isPlaying)
        case .playPause:
            guard let player else { return }
            if player.isPlaying {
                player.pause()
                isPlaying = false
            } else {
                isPlaying = player.play()
                if !isPlaying { error = "Couldn’t start playback." }
            }
        }
    }

    func checkPlayback() {
        isPlaying = player?.isPlaying == true
    }

    func close() {
        player?.stop()
        player = nil
        isPlaying = false
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        trackURL = nil
    }

    private func openTrack(autoplay: Bool) {
        close()
        let url = queue[index]
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        title = url.deletingPathExtension().lastPathComponent
        artist = ""
        artwork = nil
        error = nil
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            self.player = player
            trackURL = url
            if autoplay { execute(.playPause) }
        } catch {
            close()
            self.error = "Couldn’t open this audio file."
        }
    }

    func readMetadata() async {
        guard let url = trackURL else { return }
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        let newTitle = try? await metadata.first(where: { $0.commonKey == .commonKeyTitle })?.load(.stringValue)
        let newArtist = try? await metadata.first(where: { $0.commonKey == .commonKeyArtist })?.load(.stringValue)
        let image = try? await metadata.first(where: { $0.commonKey == .commonKeyArtwork })?.load(.dataValue)
        guard !Task.isCancelled, trackURL == url else { return }
        if let newTitle, !newTitle.isEmpty { title = String(newTitle.prefix(180)) }
        if let newArtist { artist = String(newArtist.prefix(180)) }
        if let image, image.count <= 4_194_304 {
            artwork = DesktopAudioArtwork.thumbnail(image)
        }
    }
}

private enum DesktopAudioArtwork {
    static func thumbnail(_ bytes: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...4_096).contains(width), (1...4_096).contains(height),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 256
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

struct DesktopAudioView: View {
    @State private var audio = DesktopAudioPlayer()
    @AppStorage("desktopTools.shortcut.previous") private var previous = ""
    @AppStorage("desktopTools.shortcut.playPause") private var playPause = ""
    @AppStorage("desktopTools.shortcut.next") private var next = ""
    @State private var shortcutError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 14) {
                    Group {
                        if let artwork = audio.artwork {
                            Image(nsImage: artwork).resizable().scaledToFill()
                        } else {
                            Image(systemName: "music.note").font(.largeTitle)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.teal.opacity(0.2))
                        }
                    }
                    .frame(width: 92, height: 92)
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(audio.title.isEmpty ? "Choose audio files" : audio.title)
                            .font(.headline).lineLimit(2)
                        if !audio.artist.isEmpty { Text(audio.artist).foregroundStyle(.secondary).lineLimit(1) }
                        HStack {
                            transport("Previous track", "backward.fill", .previous)
                                .disabled(!audio.hasQueue)
                            transport(audio.isPlaying ? "Pause" : "Play", audio.isPlaying ? "pause.fill" : "play.fill", .playPause)
                                .disabled(audio.trackURL == nil)
                            transport("Next track", "forward.fill", .next)
                                .disabled(!audio.hasQueue)
                        }
                    }
                    Spacer()
                    Button("Open Audio…", action: chooseAudio)
                }
                if let error = audio.error { Text(error).foregroundStyle(.red) }
                Divider()
                Text("Player Shortcuts").font(.headline)
                Text("Enter shortcuts you’ve set up to control another player. Click Run to send a command.")
                    .foregroundStyle(.secondary)
                shortcut(.previous, name: $previous)
                shortcut(.playPause, name: $playPause)
                shortcut(.next, name: $next)
                if let shortcutError { Text(shortcutError).foregroundStyle(.red) }
            }
        }
        .task(id: audio.trackURL) { await audio.readMetadata() }
        .task(id: audio.isPlaying) {
            while audio.isPlaying && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled { audio.checkPlayback() }
            }
        }
        .onDisappear { audio.close() }
    }

    private func transport(_ title: String, _ icon: String, _ command: DesktopMediaCommand) -> some View {
        Button(title, systemImage: icon) { audio.execute(command) }
            .labelStyle(.iconOnly)
            .accessibilityLabel(title)
            .help(title)
    }

    private func shortcut(_ command: DesktopMediaCommand, name: Binding<String>) -> some View {
        HStack {
            Text(command.rawValue)
                .frame(width: 100, alignment: .leading)
                .accessibilityHidden(true)
            TextField(command.rawValue, text: name, prompt: Text("Shortcut name"))
                .labelsHidden()
                .onChange(of: name.wrappedValue) { _, value in
                    if value.count > 200 { name.wrappedValue = String(value.prefix(200)) }
                    shortcutError = nil
                }
            Button("Run") {
                guard let url = DesktopMediaCommand.shortcutURL(name: name.wrappedValue),
                      NSWorkspace.shared.open(url) else {
                    shortcutError = "Couldn’t open Shortcuts. Check the shortcut name and try again."
                    return
                }
                shortcutError = nil
            }
            .disabled(DesktopMediaCommand.shortcutURL(name: name.wrappedValue) == nil)
            .accessibilityLabel("Run \(command.rawValue) shortcut")
        }
    }

    private func chooseAudio() {
        guard let parent = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: parent) { response in
            if response == .OK { audio.load(panel.urls) }
        }
    }
}
