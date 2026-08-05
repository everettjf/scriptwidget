//
//  ScriptWidgetPackage.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/10.
//

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ImageModel : Identifiable {
    let id = UUID()
    let name: String
    let path: URL
}

struct FileModel: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let relativePath: String
    let path: URL
}

/// iCloud availability of a single ubiquitous (or local) file. Surfaced so the
/// UI can tell "downloading from iCloud" apart from a real failure (issue #6).
enum ICloudItemState: Equatable {
    case local          // a non-ubiquitous file that is present on disk
    case downloaded     // ubiquitous item present locally (current)
    case downloading    // not present locally; an iCloud download is in flight
    case notInICloud    // not present and no iCloud placeholder to download from
    case error(String)  // iCloud reported a download error
}

/// Where a file's content came from when read.
enum ScriptFileSource: Equatable {
    case file        // the primary (iCloud / local) path
    case buildCache  // the local fallback cache, primary was unavailable
}

/// Outcome of reading a script file, richer than the legacy `(String?, String)`
/// tuple so callers can show a meaningful state instead of a generic error.
struct ScriptFileReadResult {
    let content: String?
    let source: ScriptFileSource?
    let icloud: ICloudItemState
    let message: String

    var succeeded: Bool { content != nil }
}

struct ScriptWidgetPackage {
    let path: URL
    let name: String
    let jsxPath: URL
    let imagePath: URL
    let metaPath: URL
    let readonly: Bool

    init(path: URL, readonly: Bool) {
        self.readonly = readonly
        self.path = path
        self.jsxPath = self.path.appendingPathComponent("main.jsx")
        self.imagePath = self.path.appendingPathComponent("image")
        self.metaPath = self.path.appendingPathComponent("meta.json")
        self.name = self.path.lastPathComponent
    }

    func readMetadata() -> ScriptMetadata? {
        guard FileManager.default.fileExists(atPath: metaPath.path) else { return nil }
        guard let data = try? Data(contentsOf: metaPath) else { return nil }
        return try? JSONDecoder().decode(ScriptMetadata.self, from: data)
    }

    func previewImageURL() -> URL? {
        let meta = readMetadata()
        let name = meta?.preview ?? "preview.png"
        let url = self.path.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    
    // readwrite
    init(path: URL) {
        self.init(path: path, readonly: false)
    }
    
    // readonly
    init(bundle: String, relativePath: String) {
        let bundleURL = Bundle.main.url(forResource: bundle, withExtension: "bundle")
        let dirPath = bundleURL!.appendingPathComponent(relativePath)
        self.init(path: dirPath, readonly: true)
    }
    
    func fileNameWithoutExtension() -> String {
        return self.name
    }
    
    func updateFiles() {
        updateDirectory(self.path)
    }
    
    func updateImages() {
        updateDirectory(self.imagePath)
    }
    
    func updateDirectory(_ dirPath: URL) {
        do {
            let items = try FileManager.default.contentsOfDirectory(atPath: dirPath.path)
            for item in items {
                let path = self.path.appendingPathComponent(item)
                
                var isDir: ObjCBool = false
                if !FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir) {
                    continue
                }
                
                if isDir.boolValue {
                    updateDirectory(path)
                } else {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: path)
                }
            }
        } catch {
            print("error : \(error)")
        }
    }
    
    func readMainFile() -> (String?, String) {
        return readFile(fullPath: self.jsxPath)
    }

    func readMainFileResult() -> ScriptFileReadResult {
        return readFileResult(fullPath: self.jsxPath)
    }

    func readFile(relativePath: String) -> (String?, String) {
        let filePath = self.path.appendingPathComponent(relativePath)
        return readFile(fullPath: filePath)
    }

    /// Legacy tuple API kept for existing callers. The second element preserves
    /// the historical status strings ("succeed" / "read from build cache: …" /
    /// error text) so behavior and tests are unchanged.
    func readFile(fullPath: URL) -> (String?, String) {
        let result = readFileResult(fullPath: fullPath)
        return (result.content, result.message)
    }

    /// Read a file, reporting where the content came from and — when it can't be
    /// read — whether iCloud is still downloading it (vs a genuine miss). Reading
    /// the primary copy succeeds first and refreshes the local build cache; if the
    /// primary is unavailable (e.g. iCloud-evicted) the build cache is the
    /// fallback. Requesting the iCloud download is deferred until the primary read
    /// fails, so a normal read stays cheap.
    func readFileResult(fullPath: URL) -> ScriptFileReadResult {
        // 1) Primary path — when present this is authoritative and (re)caches.
        if let content = try? String(contentsOf: fullPath, encoding: .utf8) {
            syncBuildCache(fullPath: fullPath, content: content)
            let state: ICloudItemState = isUbiquitous(fullPath) ? .downloaded : .local
            return ScriptFileReadResult(content: content, source: .file, icloud: state, message: "succeed")
        }

        // 2) Primary unavailable — ask iCloud to bring it back and check status.
        let icloud = requestICloudDownloadState(for: fullPath)

        // 3) Local build-cache fallback so widgets keep rendering offline.
        if let buildCachePath = buildCachePath(for: fullPath),
           let content = try? String(contentsOf: buildCachePath, encoding: .utf8) {
            return ScriptFileReadResult(content: content,
                                        source: .buildCache,
                                        icloud: icloud,
                                        message: "read from build cache: \(buildCachePath.path)")
        }

        // 4) Nothing to serve — describe why for the UI.
        let message: String
        switch icloud {
        case .downloading: message = "Downloading from iCloud"
        case .error(let e): message = e
        case .notInICloud, .local, .downloaded: message = "File not found: \(fullPath.path)"
        }
        return ScriptFileReadResult(content: nil, source: nil, icloud: icloud, message: message)
    }

    /// Whether the item at `url` is managed by iCloud (downloaded or evicted).
    func isUbiquitous(_ url: URL) -> Bool {
        return (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
    }

    /// iCloud state of a file that is *not* currently present locally, kicking off
    /// a download so a later read (or the next precache pass) can serve it.
    private func requestICloudDownloadState(for fullPath: URL) -> ICloudItemState {
        try? FileManager.default.startDownloadingUbiquitousItem(at: fullPath)

        if let values = try? fullPath.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemDownloadingErrorKey,
        ]) {
            if let error = values.ubiquitousItemDownloadingError {
                return .error("\(error)")
            }
            if values.ubiquitousItemIsDownloading == true {
                return .downloading
            }
            if let status = values.ubiquitousItemDownloadingStatus {
                switch status {
                case .current, .downloaded: return .downloaded
                default: return .downloading // requested above; not yet here
                }
            }
        }

        // No ubiquitous metadata: it's a real miss unless an evicted-item
        // placeholder (".name.icloud") is sitting next to it.
        let placeholder = fullPath.deletingLastPathComponent()
            .appendingPathComponent("." + fullPath.lastPathComponent + ".icloud")
        return FileManager.default.fileExists(atPath: placeholder.path) ? .downloading : .notInICloud
    }

    /// Current iCloud state of the package's main script file, for status UI.
    /// Does not block; reports `.downloading` once a fetch has been requested.
    func mainFileICloudState() -> ICloudItemState {
        if FileManager.default.fileExists(atPath: self.jsxPath.path) {
            return isUbiquitous(self.jsxPath) ? .downloaded : .local
        }
        return requestICloudDownloadState(for: self.jsxPath)
    }

    private func buildCachePath(for fullPath: URL) -> URL? {
        guard let buildDirectory = ScriptManager.getSandboxBuildDirectoryURL() else {
            return nil
        }
        let packageRootPath = self.path.path
        let fullPathValue = fullPath.path
        guard fullPathValue.hasPrefix(packageRootPath) else {
            return nil
        }
        var relativePath = String(fullPathValue.dropFirst(packageRootPath.count))
        if relativePath.hasPrefix("/") {
            relativePath.removeFirst()
        }
        var cacheFilePath = buildDirectory.appendingPathComponent(self.name)
        if !relativePath.isEmpty {
            cacheFilePath = cacheFilePath.appendingPathComponent(relativePath)
        }
        return cacheFilePath
    }

    private func syncBuildCache(fullPath: URL, content: String) {
        guard let cacheFilePath = buildCachePath(for: fullPath) else {
            return
        }
        guard let data = content.data(using: .utf8) else {
            return
        }
        let directory = cacheFilePath.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
                FileAttributeKey.protectionKey: FileProtectionType.none
            ])
            try data.write(to: cacheFilePath)
            try FileManager.default.setAttributes([FileAttributeKey.protectionKey: FileProtectionType.none], ofItemAtPath: cacheFilePath.path)
        } catch {
            print("sync build cache failed: \(error)")
        }
    }
    
    func makePackageDirectory() throws {
        try FileManager.default.createDirectory(at: self.path, withIntermediateDirectories: true, attributes: [
            FileAttributeKey.protectionKey : FileProtectionType.none
        ])
    }
    
    func writeFile(fullPath: URL , content: String) -> (Bool, String) {
        if self.readonly { return (false, "Package is readonly") }
        
        guard let data = content.data(using: .utf8) else { return (false, "Failed to convert code to utf8 encoding") }
        do {
            if !FileManager.default.fileExists(atPath: fullPath.path) {
                try self.makePackageDirectory()
            }
            
            try data.write(to: fullPath)
            
            try FileManager.default.setAttributes([FileAttributeKey.protectionKey: FileProtectionType.none], ofItemAtPath: fullPath.path)
            
        } catch {
            return (false, "Failed write code to path :\(fullPath) error: \(error)")
        }
        return (true, "")
    }
    
    func writeMainFile(content: String) -> (Bool,String) {
        return self.writeFile(fullPath: self.jsxPath, content: content)
    }
    
    func writeFile(relativePath: String, content: String) -> (Bool,String) {
        let fullPath = self.path.appendingPathComponent(relativePath)
        return self.writeFile(fullPath: fullPath, content: content)
    }
    
    func renameFile(relativePath: String, destRelativePath: String) -> (Bool, String) {
        let destFullPath = self.path.appendingPathComponent(destRelativePath)
        if FileManager.default.fileExists(atPath: destFullPath.path) {
            return (false, "new name existed")
        }
        let fullPath = self.path.appendingPathComponent(relativePath)
        do {
            try FileManager.default.moveItem(at: fullPath, to: destFullPath)
        } catch {
            return (false, "\(error)")
        }
        return (true, "")
    }
    
    func isFileExist(relativePath: String) -> Bool {
        let fullPath = self.path.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: fullPath.path)
    }
    
    func deleteFile(relativePath: String) {
        let fullPath = self.path.appendingPathComponent(relativePath)
        try? FileManager.default.removeItem(at: fullPath)
    }
    
    func rename(destPath: URL) -> (Bool, String) {
        if self.readonly { return (false, "Bundle file not movable")}
        
        if FileManager.default.fileExists(atPath: destPath.path) {
            return (false, "New package name already exists")
        }
        
        do {
            try FileManager.default.moveItem(at: self.path, to: destPath)
        } catch {
            return (false, "\(error)")
        }
        return (true, "")
    }
    
    func delete() -> Bool {
        do {
            try FileManager.default.removeItem(at: self.path)
        } catch {
            return false
        }
        return true
    }
    
    func getImage(_ imageName: String) -> ImageModel? {
        let imagePath = self.imagePath.appendingPathComponent(imageName).appendingPathExtension("png")
        if !FileManager.default.fileExists(atPath: imagePath.path) {
            return nil
        }
        return ImageModel(name: imageName, path: imagePath)
    }
    
    
    func getImageList() -> [ImageModel] {
        do {
            let items = try FileManager.default.contentsOfDirectory(atPath: self.imagePath.path)
            var models = [ImageModel]()
            for item in items {
                let imagePath = self.imagePath.appendingPathComponent(item)
                let imageName = imagePath.deletingPathExtension().lastPathComponent
                models.append(ImageModel(name: imageName, path: imagePath))
            }
            models.sort { a, b in
                return a.name.compare(b.name) == .orderedAscending
            }
            return models
        } catch {
            print("get image list exception: \(error)")
        }
        return []
    }
    
#if os(macOS)
    func saveImage(imagePath: URL) -> Bool {
        try? FileManager.default.createDirectory(at: self.imagePath, withIntermediateDirectories: true, attributes: [FileAttributeKey.protectionKey: FileProtectionType.none])
        
        if imagePath.pathExtension != "png" {
            return false
        }
        let fileName = imagePath.lastPathComponent
        var newFileName = fileName
        var newFilePath = self.imagePath.appendingPathComponent(newFileName)
        if FileManager.default.fileExists(atPath: newFilePath.path) {
            // file name existed, get a new name
            let count = self.getImageList().count
            newFileName = "image\(count).png"
            newFilePath = self.imagePath.appendingPathComponent(newFileName)
        }
        
        do {
            try FileManager.default.copyItem(at: imagePath, to: newFilePath)
        } catch {
            print("error = \(error)")
            return false
        }
        
        return true
    }
    func saveImage(image: NSImage, imageName: String) -> Bool {
        try? FileManager.default.createDirectory(at: self.imagePath, withIntermediateDirectories: true, attributes: [FileAttributeKey.protectionKey: FileProtectionType.none])
        
        let imagePath = self.imagePath.appendingPathComponent(imageName).appendingPathExtension("png")
        do {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return false
            }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            bitmap.size = image.size
            guard let imageData = bitmap.representation(using: .png, properties: [:]) else {
                return false
            }
            try imageData.write(to: imagePath)
            
            try FileManager.default.setAttributes([FileAttributeKey.protectionKey: FileProtectionType.none], ofItemAtPath: imagePath.path)
        } catch {
            print("save image \(error)")
            return false
        }
        return true
    }
#else
    func saveImage(image: UIImage, imageName: String) -> Bool {
        try? FileManager.default.createDirectory(at: self.imagePath, withIntermediateDirectories: true, attributes: [FileAttributeKey.protectionKey: FileProtectionType.none])
        
        let imagePath = self.imagePath.appendingPathComponent(imageName).appendingPathExtension("png")
        do {
            guard let imageData = image.pngData() else { return false }
            try imageData.write(to: imagePath)
            
            try FileManager.default.setAttributes([FileAttributeKey.protectionKey: FileProtectionType.none], ofItemAtPath: imagePath.path)
        } catch {
            print("save image \(error)")
            return false
        }
        return true
    }
#endif
    func renameImage(name: String, newName: String) -> (Bool, String) {
        let newPath = self.imagePath.appendingPathComponent("\(newName).png")
        if FileManager.default.fileExists(atPath: newPath.path) {
            return (false, "new name existed")
        }
        let oldPath = self.imagePath.appendingPathComponent("\(name).png")
        do {
            try FileManager.default.moveItem(at: oldPath, to: newPath)
            return (true, "succeed")
        } catch {
            return (false, "move failed : \(error)")
        }
    }
    
    
    func deleteImage(name: String) -> (Bool, String) {
        let path = self.imagePath.appendingPathComponent("\(name).png")
        do {
            try FileManager.default.removeItem(at: path)
            return (true, "succeed")
        } catch {
            return (false, "delete failed : \(error)")
        }
    }
    
    func listFiles() -> [FileModel] {
        return self.listFilesInternal()
    }
    
    private func listFilesInternal(_ leadingPath: String = "") -> [FileModel] {
        var curDir = self.path
        if !leadingPath.isEmpty {
            curDir = self.path.appendingPathComponent(leadingPath)
        }
        
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: curDir.path) else {
            return []
        }
        
        var items = [FileModel]()
        
        for file in files {
            let fullPath = curDir.appendingPathComponent(file)
            
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: fullPath.path, isDirectory: &isDir) {
                continue
            }
            
            if isDir.boolValue {
                var nextLeadingPath = ""
                if leadingPath.isEmpty {
                    nextLeadingPath = file
                } else {
                    nextLeadingPath = leadingPath + "/" + file
                }
                let innerFiles = self.listFilesInternal(nextLeadingPath)
                items.append(contentsOf: innerFiles)
            } else {
                if leadingPath.isEmpty {
                    items.append(FileModel(name: file, relativePath: file, path: fullPath))
                } else {
                    items.append(FileModel(name: file, relativePath: leadingPath + "/" + file, path: fullPath))
                }
            }
        }
        
        return items
    }
    
    func listRootFiles() -> [FileModel] {
        let curDir = self.path
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: curDir.path) else {
            return []
        }
        
        var items = [FileModel]()
        for file in files {
            let fullPath = curDir.appendingPathComponent(file)
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: fullPath.path, isDirectory: &isDir) {
                continue
            }
            if isDir.boolValue {
                continue
            }
            if file.suffix(4).lowercased() == ".jsx"
                || file.suffix(3).lowercased() == ".js"
                || file.suffix(5).lowercased() == ".json"
            {
                items.append(FileModel(name: file, relativePath: file, path: fullPath))
            }
        }
        
        return items.sorted { a, b in
            if a.name == "main.jsx" {
                return true
            }
            if b.name == "main.jsx" {
                return false
            }
            return a.name < b.name
        }
    }
}


let globalScriptWidgetPackage = ScriptWidgetPackage(bundle: "Script", relativePath: "template/Is Friday Today")
