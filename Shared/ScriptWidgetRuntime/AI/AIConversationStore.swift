//
//  AIConversationStore.swift
//  ScriptWidget
//
//  Keeps AI conversations as one JSON file each in the app's own Application
//  Support folder. Local to the device: not in iCloud, not in the app group,
//  so a widget extension never reads them.
//
//  What a file holds: the user's requests, the model's notes, error summaries
//  and widget sources. It holds no API key, token, request header or profile.
//

import Foundation

struct AIConversationSummary: Identifiable, Equatable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let versionCount: Int
    let isDraft: Bool
}

final class AIConversationStore {
    static let shared = AIConversationStore(directory: AIConversationStore.defaultDirectory())

    private let directory: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("ScriptWidget", isDirectory: true)
            .appendingPathComponent("AIConversations", isDirectory: true)
    }

    /// Writes the conversation, then removes the oldest ones over the limit.
    @discardableResult
    func save(_ conversation: AIConversation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(conversation)
            guard data.count <= AIConversationLimits.maxFileBytes else { return false }
            try data.write(to: fileURL(conversation.id), options: .atomic)
        } catch {
            return false
        }
        pruneLocked(keeping: conversation.id)
        return true
    }

    func load(id: UUID) -> AIConversation? {
        lock.lock()
        defer { lock.unlock() }
        return readLocked(fileURL(id))
    }

    /// Newest first. Files that cannot be read are left out, not deleted.
    func summaries(draftsOnly: Bool = false) -> [AIConversationSummary] {
        lock.lock()
        defer { lock.unlock() }
        return allLocked()
            .filter { !draftsOnly || $0.isDraft }
            .filter { !$0.turns.isEmpty }
            .map {
                AIConversationSummary(
                    id: $0.id, title: $0.title, updatedAt: $0.updatedAt,
                    versionCount: $0.versions.count, isDraft: $0.isDraft
                )
            }
    }

    /// The newest conversation saved as this widget: by manifest id when there
    /// is one, else by name.
    func latest(packageID: String?, packageName: String) -> AIConversation? {
        lock.lock()
        defer { lock.unlock() }
        return allLocked().first { conversation in
            if let packageID, let saved = conversation.savedPackageID { return saved == packageID }
            return conversation.savedPackageName == packageName
        }
    }

    func delete(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: fileURL(id))
    }

    // MARK: - private

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased() + ".json", isDirectory: false)
    }

    private func readLocked(_ url: URL) -> AIConversation? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= AIConversationLimits.maxFileBytes,
              let data = try? Data(contentsOf: url),
              var conversation = try? Self.decoder.decode(AIConversation.self, from: data),
              conversation.formatVersion == AIConversation.currentFormatVersion,
              url.deletingPathExtension().lastPathComponent == conversation.id.uuidString.lowercased()
        else { return nil }
        conversation.markRunningTurnsInterrupted()
        return conversation
    }

    private func allLocked() -> [AIConversation] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap(readLocked)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func pruneLocked(keeping kept: UUID) {
        let all = allLocked()
        guard all.count > AIConversationLimits.maxConversations else { return }
        for conversation in all.dropFirst(AIConversationLimits.maxConversations) where conversation.id != kept {
            try? fileManager.removeItem(at: fileURL(conversation.id))
        }
    }
}
