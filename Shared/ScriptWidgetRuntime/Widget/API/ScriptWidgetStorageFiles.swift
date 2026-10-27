import Foundation
import CryptoKit
import Darwin

enum ScriptWidgetStorageFileError: Error, LocalizedError {
    case unavailable, invalidData, limitExceeded
    var errorDescription: String? { "Record storage is unavailable, invalid, or exceeds its limits. Existing files have been preserved." }
}

/// Byte-exact keys preserve JavaScript keys that differ only by Unicode
/// normalization. Keys never become path components.
struct ScriptWidgetStorageFileMap {
    private var entries: [Data: (String, Any)] = [:]
    subscript(_ key: String) -> Any? {
        get { entries[Data(key.utf8)]?.1 }
        set {
            if let newValue { entries[Data(key.utf8)] = (key, newValue) }
            else { entries.removeValue(forKey: Data(key.utf8)) }
        }
    }
    var values: [(String, Any)] { entries.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { entries[$0]! } }
    var count: Int { entries.count }
}

/// Native private storage. Each owner is loaded independently; aggregate data
/// never travels through the preference daemon. Callers still authorize owners.
/// `transaction` coordinates the entire owner and atomically replaces one file.
final class ScriptWidgetStorageFiles {
    static let directoryName = "__WidgetStorage.v2"
    private static let recordMagic = Data("SWREC001".utf8)
    private static let blobMagic = Data("SWBLB001".utf8)
    private static let rootMagic = Data("SWROOT02".utf8)
    private let container: URL
    private let rootDevice: dev_t
    private let rootInode: ino_t
    private let storeReceipt: ScriptWidgetStoragePublicationReceipt
    private let volumeIdentity: Data
    private static let anchorName = ".ScriptWidgetStorage.v2.anchor"
    var storageReceipt: ScriptWidgetStoragePublicationReceipt { storeReceipt }
    private static let maximumRecordFileBytes = 3 * 1024 * 1024

    /// A genuinely absent private store permits pre-upgrade compatibility.
    /// Half-present, aliased or inaccessible state is never absence. This
    /// probe does not create a store just to check a legacy read.
    static func hasPrivateStore(container: URL, allowMissingContainer: Bool = false) throws -> Bool {
        var named = stat()
        guard lstat(container.path, &named) == 0 else {
            if allowMissingContainer && errno == ENOENT { return false }
            throw ScriptWidgetStorageFileError.unavailable
        }
        guard named.st_mode & S_IFMT == S_IFDIR else { throw ScriptWidgetStorageFileError.unavailable }
        let descriptor = open(container.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ScriptWidgetStorageFileError.unavailable }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else { throw ScriptWidgetStorageFileError.unavailable }
        try exact(descriptor, anchorName); try exact(descriptor, directoryName)
        func kind(_ name: String) throws -> mode_t? {
            var value = stat()
            guard fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { return nil }
                throw ScriptWidgetStorageFileError.unavailable
            }
            guard value.st_mode & S_IFMT != S_IFLNK,
                  value.st_mode & S_IFMT != S_IFREG || value.st_nlink == 1 else { throw ScriptWidgetStorageFileError.invalidData }
            return value.st_mode & S_IFMT
        }
        let anchor = try kind(anchorName), directory = try kind(directoryName)
        if anchor == nil && directory == nil { return false }
        guard anchor == S_IFREG, directory == S_IFDIR else { throw ScriptWidgetStorageFileError.invalidData }
        return true
    }

    init(container: URL, expectedStoreReceipt: ScriptWidgetStoragePublicationReceipt? = nil,
         legacyRecoveryRoot: URL? = ScriptWidgetStorageVolume.nativeGroupRoot, inheritedDevice: UInt64? = nil) throws {
        let root = container.standardizedFileURL.resolvingSymlinksInPath()
        var original = stat()
        guard lstat(container.path, &original) == 0, original.st_mode & S_IFMT == S_IFDIR else { throw ScriptWidgetStorageFileError.unavailable }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ScriptWidgetStorageFileError.unavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == original.st_dev, info.st_ino == original.st_ino else { throw ScriptWidgetStorageFileError.unavailable }
        self.container = root; rootDevice = info.st_dev; rootInode = info.st_ino
        let volume = try ScriptWidgetStorageVolume.identifier(fd)
        volumeIdentity = volume
        guard let result = ScriptWidgetStorageLock.withExclusiveAccess(container: root, namespace: "ScriptWidgetStorage.FileInitialization.v1", operation: { () -> Result<ScriptWidgetStoragePublicationReceipt, Error> in
            Result {
                let directory = try Self.child(fd, name: Self.directoryName)
                defer { close(directory) }
                var storeInfo = stat()
                guard fstat(directory, &storeInfo) == 0, storeInfo.st_dev == info.st_dev else { throw ScriptWidgetStorageFileError.unavailable }
                let physicalDevice = UInt64(UInt32(bitPattern: storeInfo.st_dev))
                let marker = try Self.read(directory, name: ScriptWidgetStorageVolume.markerName, maximum: 24)
                let receipt: ScriptWidgetStoragePublicationReceipt
                if let existing = try Self.read(fd, name: Self.anchorName, maximum: 24) {
                    receipt = try ScriptWidgetStorageVolume.anchorReceipt(existing)
                    guard receipt.inode == storeInfo.st_ino else { throw ScriptWidgetStorageFileError.invalidData }
                    if let marker {
                        guard marker == ScriptWidgetStorageVolume.markerMagic + volume else { throw ScriptWidgetStorageFileError.invalidData }
                    } else {
                        guard existing.prefix(8) == Data("SWANCH01".utf8) else { throw ScriptWidgetStorageFileError.invalidData }
                        // Legacy anchors stored a boot-local mount number. Only
                        // native OS-group descendants may recover a changed one;
                        // never adopt a replaced directory or arbitrary volume.
                        guard receipt.device == physicalDevice || ScriptWidgetStorageVolume.permitsLegacyRecovery(container: root, groupRoot: legacyRecoveryRoot, volume: volume) else {
                            throw ScriptWidgetStorageFileError.invalidData
                        }
                    }
                } else {
                    // Anchor publication precedes the version marker. A retry
                    // may complete an empty store, but never adopts existing
                    // data whose durable identity has gone missing.
                    guard try Self.names(directory).isEmpty else { throw ScriptWidgetStorageFileError.invalidData }
                    receipt = .init(device: inheritedDevice ?? physicalDevice, inode: storeInfo.st_ino)
                    try Self.write(Self.anchor(receipt, legacy: true), directory: fd, name: Self.anchorName)
                }
                guard expectedStoreReceipt == nil || expectedStoreReceipt == receipt else { throw ScriptWidgetStorageFileError.unavailable }
                if let marker = try Self.read(directory, name: "version", maximum: 32) {
                    guard marker == Self.rootMagic else { throw ScriptWidgetStorageFileError.invalidData }
                } else {
                    guard try Self.names(directory).isEmpty else { throw ScriptWidgetStorageFileError.invalidData }
                    try Self.write(Self.rootMagic, directory: directory, name: "version")
                }
                if marker == nil {
                    try Self.write(ScriptWidgetStorageVolume.markerMagic + volume, directory: directory, name: ScriptWidgetStorageVolume.markerName)
                }
                // The upgraded anchor requires the volume marker. A removed
                // marker can never be mistaken for a legacy store on reopen.
                let upgraded = Self.anchor(receipt)
                if try Self.read(fd, name: Self.anchorName, maximum: 24) != upgraded {
                    try Self.write(upgraded, directory: fd, name: Self.anchorName)
                }
                return receipt
            }
        }) else { throw ScriptWidgetStorageFileError.unavailable }
        storeReceipt = try result.get()
    }

    private static func anchor(_ receipt: ScriptWidgetStoragePublicationReceipt, legacy: Bool = false) -> Data {
        var bytes = Data((legacy ? "SWANCH01" : "SWANCH02").utf8)
        for value in [receipt.device, receipt.inode] {
            for index in (0..<8).reversed() { bytes.append(UInt8((value >> (index * 8)) & 255)) }
        }
        return bytes
    }

    private func bucket<T>(_ name: String, _ operation: (Int32) throws -> T) throws -> T {
        let root = open(container.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw ScriptWidgetStorageFileError.unavailable }
        defer { close(root) }
        var info = stat()
        guard fstat(root, &info) == 0, info.st_dev == rootDevice, info.st_ino == rootInode else { throw ScriptWidgetStorageFileError.unavailable }
        let directory = try Self.child(root, name: Self.directoryName)
        defer { close(directory) }
        var storeInfo = stat()
        guard fstat(directory, &storeInfo) == 0, storeInfo.st_dev == rootDevice, storeInfo.st_ino == storeReceipt.inode,
              try Self.read(root, name: Self.anchorName, maximum: 24) == Self.anchor(storeReceipt) else { throw ScriptWidgetStorageFileError.unavailable }
        guard try Self.read(directory, name: "version", maximum: 32) == Self.rootMagic else { throw ScriptWidgetStorageFileError.invalidData }
        guard try Self.read(directory, name: ScriptWidgetStorageVolume.markerName, maximum: 24) == ScriptWidgetStorageVolume.markerMagic + volumeIdentity,
              try ScriptWidgetStorageVolume.identifier(directory) == volumeIdentity else { throw ScriptWidgetStorageFileError.invalidData }
        let bucket = try Self.child(directory, name: name)
        defer { close(bucket) }
        return try operation(bucket)
    }

    private static func uuid(_ id: String) throws {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw ScriptWidgetStorageFileError.invalidData }
    }

    func readNamespace(ownerID: String) throws -> ScriptWidgetStorageFileMap {
        try Self.uuid(ownerID)
        return try bucket("records") { directory in
            guard let data = try Self.read(directory, name: ownerID + ".bin", maximum: Self.maximumRecordFileBytes) else { return .init() }
            var reader = Reader(data: data)
            guard try reader.take(8) == Self.recordMagic,
                  try reader.take(36) == Data(ownerID.utf8) else { throw ScriptWidgetStorageFileError.invalidData }
            let count = try reader.number(4)
            guard count <= ScriptWidgetStorageNamespaces.maximumNamespaceKeys else { throw ScriptWidgetStorageFileError.limitExceeded }
            var map = ScriptWidgetStorageFileMap(), total = 0, nodes = 20_000
            for _ in 0..<count {
                let keyCount = try reader.number(2), type = try reader.number(1), valueCount = try reader.number(4)
                guard (1...ScriptWidgetAtomicPreferences.maximumKeyBytes).contains(keyCount),
                      valueCount <= ScriptWidgetAtomicPreferences.maximumValueBytes else { throw ScriptWidgetStorageFileError.limitExceeded }
                total += valueCount
                guard total <= ScriptWidgetStorageNamespaces.maximumNamespaceBytes,
                      let key = String(data: try reader.take(keyCount), encoding: .utf8), map[key] == nil else { throw ScriptWidgetStorageFileError.invalidData }
                let raw = try reader.take(valueCount)
                switch type {
                case 0:
                    guard let text = String(data: raw, encoding: .utf8) else { throw ScriptWidgetStorageFileError.invalidData }
                    map[key] = text
                case 1: map[key] = raw
                case 2:
                    var format = PropertyListSerialization.PropertyListFormat.binary
                    let value = try PropertyListSerialization.propertyList(from: raw, options: [], format: &format)
                    guard format == .binary, !(value is String), !(value is Data) else { throw ScriptWidgetStorageFileError.invalidData }
                    var logicalBytes = 0
                    try Self.validate(value, depth: 0, nodes: &nodes, bytes: &logicalBytes)
                    total += max(0, logicalBytes - valueCount)
                    guard total <= ScriptWidgetStorageNamespaces.maximumNamespaceBytes else { throw ScriptWidgetStorageFileError.limitExceeded }
                    map[key] = value
                default: throw ScriptWidgetStorageFileError.invalidData
                }
            }
            guard reader.offset == data.count else { throw ScriptWidgetStorageFileError.invalidData }
            return map
        }
    }

    /// Native library profiles have separate record and identity directories.
    /// The ID comes from the private profile journal, never package metadata.
    func profileFiles(id: String, expectedStoreReceipt: ScriptWidgetStoragePublicationReceipt? = nil) throws -> ScriptWidgetStorageFiles {
        try Self.uuid(id)
        return try bucket("profiles") { parent in
            let descriptor = try Self.child(parent, name: id)
            defer { close(descriptor) }
            var receipt = stat()
            guard fstat(descriptor, &receipt) == 0 else { throw ScriptWidgetStorageFileError.unavailable }
            let path = container.appendingPathComponent(Self.directoryName).appendingPathComponent("profiles").appendingPathComponent(id)
            let files = try ScriptWidgetStorageFiles(container: path, expectedStoreReceipt: expectedStoreReceipt, inheritedDevice: storeReceipt.device)
            guard files.rootDevice == receipt.st_dev, files.rootInode == receipt.st_ino else { throw ScriptWidgetStorageFileError.unavailable }
            return files
        }
    }

    /// Code/resources are cached inside the selected private library profile.
    /// No script or package manifest supplies this directory name or its root.
    func widgetCacheDirectory() throws -> URL {
        try bucket("widget-cache") { _ in
            container.appendingPathComponent(Self.directoryName).appendingPathComponent("widget-cache")
        }
    }

    /// For native coordinators already holding the owner's lock, or a migration
    /// registry lock while this owner remains inaccessible pending review.
    func commitNamespace(ownerID: String, values: ScriptWidgetStorageFileMap) throws {
        try Self.uuid(ownerID)
        guard values.count <= ScriptWidgetStorageNamespaces.maximumNamespaceKeys else { throw ScriptWidgetStorageFileError.limitExceeded }
        var data = Self.recordMagic; data.append(contentsOf: ownerID.utf8); Self.append(values.count, bytes: 4, to: &data)
        var total = 0, nodes = 20_000
        for (key, value) in values.values {
            let name = Data(key.utf8), raw: Data, type: Int
            guard (1...ScriptWidgetAtomicPreferences.maximumKeyBytes).contains(name.count) else { throw ScriptWidgetStorageFileError.limitExceeded }
            var logicalBytes = 0
            if let text = value as? String {
                guard text.utf8.count <= ScriptWidgetAtomicPreferences.maximumValueBytes else { throw ScriptWidgetStorageFileError.limitExceeded }
                raw = Data(text.utf8); type = 0
            }
            else if let bytes = value as? Data { raw = bytes; type = 1 }
            else {
                try Self.validate(value, depth: 0, nodes: &nodes, bytes: &logicalBytes)
                raw = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0); type = 2
            }
            total += max(raw.count, logicalBytes)
            guard raw.count <= ScriptWidgetAtomicPreferences.maximumValueBytes,
                  total <= ScriptWidgetStorageNamespaces.maximumNamespaceBytes else { throw ScriptWidgetStorageFileError.limitExceeded }
            Self.append(name.count, bytes: 2, to: &data); Self.append(type, bytes: 1, to: &data); Self.append(raw.count, bytes: 4, to: &data)
            data.append(name); data.append(raw)
        }
        guard data.count <= Self.maximumRecordFileBytes else { throw ScriptWidgetStorageFileError.limitExceeded }
        try bucket("records") { try Self.write(data, directory: $0, name: ownerID + ".bin") }
    }

    func transaction(ownerID: String, _ operation: (inout ScriptWidgetStorageFileMap) throws -> Bool) throws -> Bool {
        try Self.uuid(ownerID)
        guard let result = ScriptWidgetStorageLock.withExclusiveAccess(container: container, namespace: "ScriptWidgetStorage.v2:" + ownerID + ":", operation: { () -> Result<Bool, Error> in
            Result {
                var values = try readNamespace(ownerID: ownerID)
                guard try operation(&values) else { return false }
                try commitNamespace(ownerID: ownerID, values: values)
                return true
            }
        }) else { throw ScriptWidgetStorageFileError.unavailable }
        return try result.get()
    }

    func readMetadata(key: String) throws -> Data? {
        let keyBytes = Data(key.utf8)
        guard (1...256).contains(keyBytes.count) else { throw ScriptWidgetStorageFileError.limitExceeded }
        let name = SHA256.hash(data: keyBytes).map { String(format: "%02x", $0) }.joined() + ".bin"
        return try bucket("metadata") { directory in
            guard let data = try Self.read(directory, name: name, maximum: ScriptWidgetStorageNamespaces.maximumRegistryBytes + 272) else { return nil }
            var reader = Reader(data: data)
            guard try reader.take(8) == Self.blobMagic else { throw ScriptWidgetStorageFileError.invalidData }
            let size = try reader.number(2), count = try reader.number(4)
            guard size == keyBytes.count, count <= ScriptWidgetStorageNamespaces.maximumRegistryBytes,
                  try reader.take(size) == keyBytes else { throw ScriptWidgetStorageFileError.invalidData }
            let value = try reader.take(count)
            guard reader.offset == data.count else { throw ScriptWidgetStorageFileError.invalidData }
            return value
        }
    }

    /// Metadata coordination/journaling belongs to the native identity layer.
    func writeMetadata(key: String, data: Data) throws {
        let keyBytes = Data(key.utf8)
        guard (1...256).contains(keyBytes.count), data.count <= ScriptWidgetStorageNamespaces.maximumRegistryBytes else { throw ScriptWidgetStorageFileError.limitExceeded }
        var frame = Self.blobMagic; Self.append(keyBytes.count, bytes: 2, to: &frame); Self.append(data.count, bytes: 4, to: &frame)
        frame.append(keyBytes); frame.append(data)
        let name = SHA256.hash(data: keyBytes).map { String(format: "%02x", $0) }.joined() + ".bin"
        try bucket("metadata") { try Self.write(frame, directory: $0, name: name) }
    }

    /// Only the native coordinator removes completed journal entries. A corrupt
    /// or substituted entry is preserved for recovery instead of silently erased.
    func removeMetadata(key: String) throws {
        guard try readMetadata(key: key) != nil else { return }
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".bin"
        try bucket("metadata") { directory in
            try Self.exact(directory, name)
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  unlinkat(directory, name, 0) == 0 else { throw ScriptWidgetStorageFileError.unavailable }
            _ = fsync(directory)
        }
    }

    private static func validate(_ value: Any, depth: Int, nodes: inout Int, bytes: inout Int) throws {
        nodes -= 1
        guard nodes >= 0, depth <= 16 else { throw ScriptWidgetStorageFileError.limitExceeded }
        if let text = value as? String { bytes += text.utf8.count }
        else if let data = value as? Data { bytes += data.count }
        else if value is Date || value is NSNumber { bytes += 16 }
        else if let array = value as? [Any] {
            bytes += array.count
            guard bytes <= ScriptWidgetAtomicPreferences.maximumValueBytes else { throw ScriptWidgetStorageFileError.limitExceeded }
            for item in array { try validate(item, depth: depth + 1, nodes: &nodes, bytes: &bytes) }
        } else if let dictionary = value as? [String: Any] {
            for (key, item) in dictionary {
                guard key.utf8.count <= 256 else { throw ScriptWidgetStorageFileError.limitExceeded }
                bytes += key.utf8.count
                try validate(item, depth: depth + 1, nodes: &nodes, bytes: &bytes)
            }
        } else { throw ScriptWidgetStorageFileError.invalidData }
        guard bytes <= ScriptWidgetAtomicPreferences.maximumValueBytes else { throw ScriptWidgetStorageFileError.limitExceeded }
    }

    private struct Reader {
        let data: Data
        var offset = 0
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= data.count - offset else { throw ScriptWidgetStorageFileError.invalidData }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
        mutating func number(_ bytes: Int) throws -> Int {
            let value = try take(bytes)
            return value.reduce(0) { ($0 << 8) | Int($1) }
        }
    }
    private static func append(_ value: Int, bytes: Int, to data: inout Data) {
        for index in (0..<bytes).reversed() { data.append(UInt8((value >> (index * 8)) & 255)) }
    }

    private static func names(_ fd: Int32) throws -> [String] {
        // dup shares the directory offset. Reopening "." gives each scan its
        // own offset, so repeated canonical-name checks cannot see false emptiness.
        let scan = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard scan >= 0 else { throw ScriptWidgetStorageFileError.unavailable }
        guard let directory = fdopendir(scan) else { close(scan); throw ScriptWidgetStorageFileError.unavailable }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw ScriptWidgetStorageFileError.unavailable }
                break
            }
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
            guard names.count <= 8192 else { throw ScriptWidgetStorageFileError.limitExceeded }
        }
        return names
    }
    private static func exact(_ parent: Int32, _ name: String) throws {
        let matches = try names(parent).filter { $0.precomposedStringWithCanonicalMapping.lowercased() == name.lowercased() }
        guard matches.isEmpty || (matches.count == 1 && matches[0].utf8.elementsEqual(name.utf8)) else { throw ScriptWidgetStorageFileError.invalidData }
    }
    private static func child(_ parent: Int32, name: String) throws -> Int32 {
        try exact(parent, name)
        guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else { throw ScriptWidgetStorageFileError.unavailable }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ScriptWidgetStorageFileError.invalidData }
        return fd
    }
    private static func read(_ parent: Int32, name: String, maximum: Int) throws -> Data? {
        try exact(parent, name)
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw ScriptWidgetStorageFileError.unavailable
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= maximum else { throw ScriptWidgetStorageFileError.invalidData }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ScriptWidgetStorageFileError.unavailable }
                offset += count
            }
        }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              after.st_dev == info.st_dev, after.st_ino == info.st_ino, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec,
              named.st_dev == info.st_dev, named.st_ino == info.st_ino else { throw ScriptWidgetStorageFileError.unavailable }
        return data
    }

    #if os(iOS) && !targetEnvironment(simulator)
    private static let protection: Int32? = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StorageProtection-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        do { try Data().write(to: url, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication]) } catch { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        let value = fcntl(fd, F_GETPROTECTIONCLASS)
        return value >= 0 ? value : nil
    }()
    #endif

    private static func write(_ data: Data, directory: Int32, name: String) throws {
        try exact(directory, name)
        var existing = stat()
        if fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1 else { throw ScriptWidgetStorageFileError.invalidData }
        } else if errno != ENOENT { throw ScriptWidgetStorageFileError.unavailable }
        let temporary = ".write-" + UUID().uuidString.lowercased()
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ScriptWidgetStorageFileError.unavailable }
        defer { close(fd); _ = unlinkat(directory, temporary, 0) }
        #if os(iOS) && !targetEnvironment(simulator)
        guard let protection, fcntl(fd, F_SETPROTECTIONCLASS, protection) == 0 else { throw ScriptWidgetStorageFileError.unavailable }
        #endif
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ScriptWidgetStorageFileError.unavailable }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directory, temporary, directory, name) == 0 else { throw ScriptWidgetStorageFileError.unavailable }
        _ = fsync(directory)
    }
}

/// File-backed coordinator access. Original script.* preferences are read-only;
/// neither imported scripts nor a public package ID select a file owner. Native
/// callers authorize identity and hold the registry/owner lock before mutation.
final class ScriptWidgetFileStorageBackend: ScriptWidgetStorageBackend {
    let files: ScriptWidgetStorageFiles
    private let legacy: UserDefaults
    private let includesLegacy: Bool
    private static let prefix = "ScriptWidgetStorage.v2:"
    private static let metadataKeys: Set<String> = [
        ScriptWidgetStorageNamespaces.registryKey, ScriptWidgetStorageNamespaces.directoriesKey,
        ScriptWidgetStorageNamespaces.installationKey, ScriptWidgetStorageNamespaces.relocationKey,
        ScriptWidgetStorageNamespaces.replacementKey, ScriptWidgetStorageNamespaces.cleanupKey
    ]

    init(container: URL, legacy: UserDefaults) throws {
        files = try ScriptWidgetStorageFiles(container: container)
        self.legacy = legacy
        includesLegacy = true
    }

    init(files: ScriptWidgetStorageFiles, legacy: UserDefaults, includesLegacy: Bool) {
        self.files = files; self.legacy = legacy; self.includesLegacy = includesLegacy
    }

    private func recordKey(_ key: String) throws -> (owner: String, suffix: String)? {
        let bytes = Array(key.utf8), prefix = Array(Self.prefix.utf8)
        guard bytes.starts(with: prefix) else { return nil }
        let remainder = Array(bytes.dropFirst(prefix.count))
        guard remainder.count > 37, remainder[36] == 58 else { throw ScriptWidgetStorageFileError.invalidData }
        let owner = String(decoding: remainder.prefix(36), as: UTF8.self)
        let suffix = String(decoding: remainder.dropFirst(37), as: UTF8.self)
        guard UUID(uuidString: owner)?.uuidString.lowercased() == owner,
              !suffix.isEmpty, suffix.utf8.count <= ScriptWidgetAtomicPreferences.maximumKeyBytes else { throw ScriptWidgetStorageFileError.invalidData }
        return (owner, suffix)
    }

    private func owner(_ namespace: String) throws -> String {
        guard namespace.hasSuffix(":"), let parsed = try recordKey(namespace + "key"),
              namespace == Self.prefix + parsed.owner + ":" else { throw ScriptWidgetStorageFileError.invalidData }
        return parsed.owner
    }

    private func metadata(_ key: String) -> Bool {
        if Self.metadataKeys.contains(key) { return true }
        let servicePrefix = "ScriptWidget.SystemServices."
        if key.hasPrefix(servicePrefix) {
            let parts = key.dropFirst(servicePrefix.count).split(separator: ".", omittingEmptySubsequences: false)
            let kinds: Set<String> = ["alarmKeys", "alarmReceipts", "ownedEvents", "calendarReceipts", "homeReceipts", "weatherCache"]
            guard parts.count == 3, kinds.contains(String(parts[0])), parts[1] == "v1" else { return false }
            let owner = String(parts[2])
            return UUID(uuidString: owner)?.uuidString.lowercased() == owner
        }
        return ["ScriptWidget.CalendarCache.v1.", "ScriptWidget.RemindersCache.v1.", "ScriptWidget.RemindersWrites.v1.", "ScriptWidget.PhotosCache.v1."].contains { prefix in
            let suffix = key.dropFirst(prefix.count)
            return key.hasPrefix(prefix) && suffix.count == 64 && suffix.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }

    func readValue(forKey key: String) throws -> Any? {
        if let record = try recordKey(key) { return try files.readNamespace(ownerID: record.owner)[record.suffix] }
        if metadata(key) { return try files.readMetadata(key: key) }
        guard key.hasPrefix("script.") else { throw ScriptWidgetStorageFileError.invalidData }
        return includesLegacy ? legacy.object(forKey: key) : nil
    }

    func writeValue(_ value: Any, forKey key: String) throws {
        if let record = try recordKey(key) {
            var map = try files.readNamespace(ownerID: record.owner)
            map[record.suffix] = value
            try files.commitNamespace(ownerID: record.owner, values: map)
        } else {
            guard metadata(key), let bytes = value as? Data else { throw ScriptWidgetStorageFileError.invalidData }
            try files.writeMetadata(key: key, data: bytes)
        }
    }

    func removeValue(forKey key: String) throws {
        if let record = try recordKey(key) {
            var map = try files.readNamespace(ownerID: record.owner)
            map[record.suffix] = nil
            try files.commitNamespace(ownerID: record.owner, values: map)
        } else {
            guard metadata(key) else { throw ScriptWidgetStorageFileError.invalidData }
            try files.removeMetadata(key: key)
        }
    }

    func legacyValues() -> [String: Any] { includesLegacy ? legacy.dictionaryRepresentation().filter { $0.key.hasPrefix("script.") } : [:] }
    // File mutations finish (or throw) before returning. The legacy preferences
    // are read-only migration input, so their flush status cannot determine
    // whether this backend's file transaction succeeded.
    func synchronize() -> Bool { true }
    func values(in namespace: String) throws -> [(String, Any)] {
        let owner = try owner(namespace)
        return try files.readNamespace(ownerID: owner).values.map { (namespace + $0.0, $0.1) }
    }
}

extension ScriptWidgetFileStorageBackend {
    /// AtomicPreferences already holds the namespace lock. The coordinator's
    /// identity lookups delegate to metadata without acquiring a second owner
    /// lock. No shared mutable transaction state is kept on the backend.
    func mutateValues(in namespace: String, operation: (any ScriptWidgetStorageBackend) throws -> Bool) throws -> Bool {
        let owner = try owner(namespace)
        let staged = Transaction(parent: self, namespace: namespace, map: try files.readNamespace(ownerID: owner))
        guard try operation(staged) else { return false }
        try files.commitNamespace(ownerID: owner, values: staged.map)
        return true
    }

    private final class Transaction: ScriptWidgetStorageBackend {
        let parent: ScriptWidgetFileStorageBackend
        let namespace: String
        var map: ScriptWidgetStorageFileMap
        init(parent: ScriptWidgetFileStorageBackend, namespace: String, map: ScriptWidgetStorageFileMap) {
            self.parent = parent; self.namespace = namespace; self.map = map
        }
        private func suffix(_ key: String) throws -> String {
            guard key.utf8.starts(with: namespace.utf8) else { throw ScriptWidgetStorageFileError.invalidData }
            let suffix = String(decoding: key.utf8.dropFirst(namespace.utf8.count), as: UTF8.self)
            guard !suffix.isEmpty, suffix.utf8.count <= ScriptWidgetAtomicPreferences.maximumKeyBytes else { throw ScriptWidgetStorageFileError.invalidData }
            return suffix
        }
        func readValue(forKey key: String) throws -> Any? {
            if key.utf8.starts(with: namespace.utf8) { return map[try suffix(key)] }
            // Native identity checks may read journals/registry while an owner
            // transaction is active, but cannot read a second owner's records.
            guard !key.hasPrefix(ScriptWidgetFileStorageBackend.prefix) else { throw ScriptWidgetStorageFileError.invalidData }
            return try parent.readValue(forKey: key)
        }
        func writeValue(_ value: Any, forKey key: String) throws { map[try suffix(key)] = value }
        func removeValue(forKey key: String) throws { map[try suffix(key)] = nil }
        func values(in namespace: String) throws -> [(String, Any)] {
            guard namespace == self.namespace else { throw ScriptWidgetStorageFileError.invalidData }
            return map.values.map { (namespace + $0.0, $0.1) }
        }
        func legacyValues() throws -> [String: Any] { throw ScriptWidgetStorageFileError.invalidData }
        func synchronize() -> Bool { true }
        func mutateValues(in namespace: String, operation: (any ScriptWidgetStorageBackend) throws -> Bool) throws -> Bool {
            throw ScriptWidgetStorageFileError.invalidData
        }
    }
}
