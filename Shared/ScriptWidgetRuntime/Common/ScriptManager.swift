//
//  ScriptManager.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/11/10.
//

import Foundation
import SwiftUI
import ZipArchive


extension String {
    
    func trim() -> String {
        return self.trimmingCharacters(in: .whitespaces)
    }
    
    func checkIfValidFileName() -> Bool {
        let checkPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scriptwidget-filename-check-\(self)")
        do {
            let testString = "1"
            try testString.write(to: checkPath, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: checkPath)
        } catch {
            return false
        }
        return true
    }
    
}

struct ScriptPackageImportResult: Equatable {
    let succeeded: Bool
    let packageName: String?
    let message: String
    let validation: WidgetPackageValidationReport?
}

enum ScriptPackageArchivePolicy {
    static let maximumArchiveBytes = 32 * 1024 * 1024
    static let maximumExpandedBytes = 64 * 1024 * 1024
    static let maximumFileBytes = 25 * 1024 * 1024
    static let maximumFileCount = 500
    static let maximumPathDepth = 16
}

enum ScriptPackageArchivePreflight {
    static func validate(_ archiveURL: URL) -> String? {
        guard let values = try? archiveURL.resourceValues(forKeys: [.fileSizeKey]),
              let archiveBytes = values.fileSize,
              archiveBytes > 0,
              archiveBytes <= ScriptPackageArchivePolicy.maximumArchiveBytes else {
            return "Archive must be between 1 byte and 32 MiB."
        }
        guard let data = try? Data(contentsOf: archiveURL) else {
            return "Archive could not be read."
        }
        guard let end = endOfCentralDirectory(in: data) else {
            return "Archive has no valid ZIP central directory."
        }
        guard data.uint16LE(at: end + 4) == 0,
              data.uint16LE(at: end + 6) == 0,
              data.uint16LE(at: end + 8) == data.uint16LE(at: end + 10) else {
            return "Multi-disk ZIP archives are not supported."
        }
        let commentLength = Int(data.uint16LE(at: end + 20))
        guard end + 22 + commentLength == data.count else {
            return "Archive has a malformed ZIP footer."
        }
        let entries = Int(data.uint16LE(at: end + 10))
        let centralSize = Int(data.uint32LE(at: end + 12))
        let centralOffset = Int(data.uint32LE(at: end + 16))
        guard entries > 0, entries <= ScriptPackageArchivePolicy.maximumFileCount else {
            return "Archive must contain 1–\(ScriptPackageArchivePolicy.maximumFileCount) entries."
        }
        guard centralOffset >= 0, centralSize >= 0,
              centralOffset + centralSize <= data.count else {
            return "Archive central directory is out of bounds."
        }

        var cursor = centralOffset
        var expandedBytes: UInt64 = 0
        var normalizedPaths: Set<String> = []
        for _ in 0..<entries {
            guard cursor + 46 <= data.count,
                  data.uint32LE(at: cursor) == 0x02014B50 else {
                return "Archive central directory contains an invalid entry."
            }
            let flags = data.uint16LE(at: cursor + 8)
            let method = data.uint16LE(at: cursor + 10)
            let compressed32 = data.uint32LE(at: cursor + 20)
            let uncompressed32 = data.uint32LE(at: cursor + 24)
            let nameLength = Int(data.uint16LE(at: cursor + 28))
            let extraLength = Int(data.uint16LE(at: cursor + 30))
            let commentLength = Int(data.uint16LE(at: cursor + 32))
            let externalAttributes = data.uint32LE(at: cursor + 38)
            let entryEnd = cursor + 46 + nameLength + extraLength + commentLength
            guard nameLength > 0, entryEnd <= data.count else {
                return "Archive contains a truncated filename."
            }
            guard let sizes = resolvedSizes(
                compressed32: compressed32,
                uncompressed32: uncompressed32,
                extra: data.subdata(in: (cursor + 46 + nameLength)..<(cursor + 46 + nameLength + extraLength))
            ) else { return "Archive contains malformed ZIP64 size metadata." }
            let compressed = sizes.compressed
            let uncompressed = sizes.uncompressed
            guard flags & 0x1 == 0 else { return "Encrypted package entries are not supported." }
            guard method == 0 || method == 8 else { return "Unsupported ZIP compression method \(method)." }
            let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            guard let name = String(data: nameData, encoding: .utf8), validEntryPath(name) else {
                return "Archive contains an unsafe or non-UTF-8 path."
            }
            let normalizedPath = name.precomposedStringWithCanonicalMapping.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard normalizedPaths.insert(normalizedPath).inserted else {
                return "Archive contains duplicate or case-colliding paths."
            }
            let unixMode = UInt16((externalAttributes >> 16) & 0xFFFF)
            if unixMode & 0xF000 == 0xA000 {
                return "Symbolic links are not allowed in ScriptWidget packages."
            }
            if !name.hasSuffix("/") {
                guard uncompressed <= UInt64(ScriptPackageArchivePolicy.maximumFileBytes) else {
                    return "Package file \(name) exceeds 25 MiB."
                }
                expandedBytes += uncompressed
                guard expandedBytes <= UInt64(ScriptPackageArchivePolicy.maximumExpandedBytes) else {
                    return "Expanded package exceeds 64 MiB."
                }
                if uncompressed > 1024 * 1024, compressed == 0 {
                    return "Archive entry \(name) has an invalid compression ratio."
                }
            }
            cursor = entryEnd
        }
        guard cursor == centralOffset + centralSize else {
            return "Archive entries do not match the declared central directory."
        }
        return nil
    }

    private static func validEntryPath(_ name: String) -> Bool {
        guard !name.hasPrefix("/"), !name.hasPrefix("\\"), !name.contains("\\"), !name.contains(":"), !name.contains("\0") else {
            return false
        }
        let parts = name.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, parts.count <= ScriptPackageArchivePolicy.maximumPathDepth else { return false }
        return parts.allSatisfy { $0 != "." && $0 != ".." }
    }

    private static func resolvedSizes(compressed32: UInt32, uncompressed32: UInt32, extra: Data) -> (compressed: UInt64, uncompressed: UInt64)? {
        var compressed = UInt64(compressed32)
        var uncompressed = UInt64(uncompressed32)
        guard compressed32 == UInt32.max || uncompressed32 == UInt32.max else { return (compressed, uncompressed) }

        var cursor = 0
        while cursor + 4 <= extra.count {
            let identifier = extra.uint16LE(at: cursor)
            let length = Int(extra.uint16LE(at: cursor + 2))
            let end = cursor + 4 + length
            guard end <= extra.count else { return nil }
            if identifier == 0x0001 {
                var valueCursor = cursor + 4
                if uncompressed32 == UInt32.max {
                    guard valueCursor + 8 <= end else { return nil }
                    uncompressed = extra.uint64LE(at: valueCursor)
                    valueCursor += 8
                }
                if compressed32 == UInt32.max {
                    guard valueCursor + 8 <= end else { return nil }
                    compressed = extra.uint64LE(at: valueCursor)
                }
                return (compressed, uncompressed)
            }
            cursor = end
        }
        return nil
    }

    private static func endOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowerBound = max(0, data.count - 65_557)
        var index = data.count - 22
        while index >= lowerBound {
            if data.uint32LE(at: index) == 0x06054B50 { return index }
            index -= 1
        }
        return nil
    }
}

private extension Data {
    func uint16LE(at index: Int) -> UInt16 {
        guard index >= 0, index + 2 <= count else { return 0 }
        return UInt16(self[index]) | (UInt16(self[index + 1]) << 8)
    }

    func uint32LE(at index: Int) -> UInt32 {
        guard index >= 0, index + 4 <= count else { return 0 }
        return UInt32(self[index])
            | (UInt32(self[index + 1]) << 8)
            | (UInt32(self[index + 2]) << 16)
            | (UInt32(self[index + 3]) << 24)
    }

    func uint64LE(at index: Int) -> UInt64 {
        guard index >= 0, index + 8 <= count else { return 0 }
        return (0..<8).reduce(UInt64(0)) { result, offset in
            result | (UInt64(self[index + offset]) << UInt64(offset * 8))
        }
    }
}



class ScriptManager {
    
    let scriptDirectory: URL
    let isUsingiCloud: Bool
    let isBuild: Bool
    
    init(isBuild: Bool) {
        self.isBuild = isBuild
        if isBuild {
            if let buildDir = Self.getSandboxBuildDirectoryURL() {
                self.scriptDirectory = buildDir
            } else {
                print("app group container unavailable; falling back to local build directory")
                self.scriptDirectory = Self.localFallbackDirectoryURL("__Build")
            }
            self.isUsingiCloud = false
        } else {
            let dirInfo = Self.getICloudPriorityRootDirectory()
            self.scriptDirectory = dirInfo.0
            self.isUsingiCloud = dirInfo.1
            
            print("icloud dir : \(isUsingiCloud)")
            print("root = \(String(describing: scriptDirectory))")
            
        }
        self.makeSureRootExist()
    }
    
    static func getICloudPriorityRootDirectory() -> (URL, Bool) {
        var isUsingiCloud = false
        var root = URL(fileURLWithPath: "")
        if let url = ScriptManager.getICloudRootDirectoryURL() {
            root = url
            isUsingiCloud = true
        } else if let sandboxRoot = ScriptManager.getSandboxRootDirectoryURL() {
            root = sandboxRoot
            isUsingiCloud = false
        } else {
            print("app group container unavailable; falling back to local root directory")
            root = ScriptManager.localFallbackDirectoryURL("Documents")
            isUsingiCloud = false
        }
        
        let scriptRoot = root.appendingPathComponent("Scripts")
        return (scriptRoot, isUsingiCloud)
    }
    
    func makeSureRootExist() {
        self.makeSureDirectoryExist(path: self.scriptDirectory)
    }
    func makeSureDirectoryExist(path: URL) {
        do {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [
                FileAttributeKey.protectionKey : FileProtectionType.none
            ])
        } catch {
            print("create root dir failed : \(error)")
        }
    }
    
    
    static func getICloudRootDirectoryURL() -> URL? {
        if let url = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.ScriptWidget") {
            return url.appendingPathComponent("Documents")
        }
        return nil
    }
    
    static func getSandboxRootDirectoryURL() -> URL? {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget") {
            return url.appendingPathComponent("Documents")
        }
        return nil
    }
    
    static func getSandboxBuildDirectoryURL() -> URL? {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.everettjf.scriptwidget") {
            let buildURL = url.appendingPathComponent("__Build")
            do {
                try FileManager.default.createDirectory(at: buildURL, withIntermediateDirectories: true)
                let probe = buildURL.appendingPathComponent(".write-probe-\(UUID().uuidString)")
                try Data().write(to: probe)
                try FileManager.default.removeItem(at: probe)
                return buildURL
            } catch {
                // Unsigned CI test hosts can resolve the group URL without being
                // allowed to write it. Keep cache tests and local previews usable.
                return localFallbackDirectoryURL("__Build")
            }
        }
        return localFallbackDirectoryURL("__Build")
    }

    /// Local, per-process fallback used when the shared app-group container is
    /// unavailable (e.g. a missing entitlement). Keeps the app functional with
    /// local-only storage instead of crashing on a force-unwrap. Prefers
    /// Application Support and degrades to the temporary directory.
    static func localFallbackDirectoryURL(_ component: String) -> URL {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("ScriptWidgetTests")
                .appendingPathComponent(component)
        }
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ScriptWidget").appendingPathComponent(component)
    }
    
    static func getSandboxFileCount() -> Int {
        if let url = ScriptManager.getSandboxRootDirectoryURL() {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                return 0
            }
            
            return items.filter { item in
                return item != "__Build"
            }
            .count
        }
        return 0
    }
    
    static func moveSandboxFilesToICloud() -> Bool {
        guard let icloudUrl = ScriptManager.getICloudRootDirectoryURL() else { return false }
        guard let sandboxUrl = ScriptManager.getSandboxRootDirectoryURL() else { return false }
        
        var errorOccur = false
        guard let sandboxItems = try? FileManager.default.contentsOfDirectory(atPath: sandboxUrl.path) else { return false }
        for item in sandboxItems {
            if item == "__Build" {
                continue
            }
            
            let srcRoot = sandboxUrl.appendingPathComponent(item)
            let destRoot = icloudUrl.appendingPathComponent(item)
            
            // make sure destRoot exist
            try? FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true, attributes: [
                FileAttributeKey.protectionKey : FileProtectionType.none
            ])
            
            // move each item in root
            if let files = try? FileManager.default.contentsOfDirectory(atPath: srcRoot.path) {
                
                for fileName in files {
                    let srcPath = srcRoot.appendingPathComponent(fileName)
                    var destPath = destRoot.appendingPathComponent(fileName)
                    
                    let fileExt = destPath.pathExtension
                    let fileNameNoExt = destPath.deletingPathExtension().lastPathComponent
                    
                    for index in 1...1000 {
                        if !FileManager.default.fileExists(atPath: destPath.path) {
                            break
                        }
                        destPath = destRoot.appendingPathComponent("\(fileNameNoExt) (\(index)).\(fileExt)")
                    }
                    
                    print("will move \(srcPath) to \(destPath)")
                    
                    do {
                        // make sure succeed
                        try FileManager.default.moveItem(at: srcPath, to: destPath)
                        
                        // succeed, delete src, ignore result
                        try? FileManager.default.removeItem(at: srcPath)
                        
                        print("move done")
                    } catch {
                        print("error occur = \(error)")
                        errorOccur = true
                    }
                }
            }
            
            if !errorOccur {
                // remove srcRoot
                try? FileManager.default.removeItem(at: srcRoot)
            }

        }
        
        return !errorOccur
    }
    
    func isICloudAvaliable() -> Bool {
        if let _ = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            return true
        } else {
            return false
        }
    }
    
    func getPackagePathFromPackageName(packageName: String) -> URL {
        return self.scriptDirectory.appendingPathComponent(packageName)
    }
    
    func saveScript(packageName: String, content: String, imageCopyPath: URL?) -> (Bool,String) {
        let packagePath = self.getPackagePathFromPackageName(packageName: packageName)
        let package = ScriptWidgetPackage(path: packagePath)
        let result = package.writeMainFile(content: content)

        if let imageCopyPath = imageCopyPath {
            // copy images to package
            let targetDir = package.imagePath
            try? FileManager.default.copyItem(at: imageCopyPath, to: targetDir)
        }

        if result.0, package.readManifest() == nil {
            let manifestResult = package.writeManifest(.newProject(name: packageName))
            guard manifestResult.0 else { return manifestResult }
        }

        if result.0, !self.isBuild {
            _ = buildScriptPackage(package: package)
        }
        
        return result
    }
    
    func renameScript(srcPackageName: String, destPackageName: String) -> (Bool, String) {
        if srcPackageName == destPackageName {
            return (true, "No need rename")
        }
        let srcScriptPath = self.getPackagePathFromPackageName(packageName: srcPackageName)
        let destScriptPath = self.getPackagePathFromPackageName(packageName: destPackageName)

        let file = ScriptWidgetPackage(path: srcScriptPath)
        let renameResult = file.rename(destPath: destScriptPath)
        if renameResult.0, !self.isBuild {
            _ = removeBuildScriptPackage(package: file)
            let newPackage = self.getScriptPackage(packageName: destPackageName)
            _ = buildScriptPackage(package: newPackage)
        }
        return renameResult
    }
    
    func getValidPackageName(recommendPackageName: String) -> String {
        var packageName = recommendPackageName
        if self.isExist(packageName: packageName) {
            for index in 1...10000 {
                let newId = "\(recommendPackageName) (\(index))"
                if !self.isExist(packageName: newId) {
                    packageName = newId
                    break
                }
            }
        }
        return packageName
    }
    
    func createScript(content: String, recommendPackageName: String, imageCopyPath: URL?) -> (Bool,String) {
        // get valid id (name)
        let packageName = self.getValidPackageName(recommendPackageName: recommendPackageName)
        return self.saveScript(packageName: packageName, content: content, imageCopyPath: imageCopyPath)
    }

    /// Duplicate an existing script into a new package. Returns the new package name on success.
    func duplicateScript(sourcePackageName: String) -> (Bool, String) {
        let srcPath = self.getPackagePathFromPackageName(packageName: sourcePackageName)
        guard FileManager.default.fileExists(atPath: srcPath.path) else {
            return (false, "Source not found")
        }
        let newName = self.getValidPackageName(recommendPackageName: "\(sourcePackageName) Remix")
        let destPath = self.getPackagePathFromPackageName(packageName: newName)
        do {
            try FileManager.default.copyItem(at: srcPath, to: destPath)
        } catch {
            return (false, "Failed to duplicate: \(error.localizedDescription)")
        }
        if !self.isBuild {
            let package = self.getScriptPackage(packageName: newName)
            _ = buildScriptPackage(package: package)
        }
        return (true, newName)
    }
    
    
    func isExist(packageName: String) -> Bool {
        let dirPath = self.getPackagePathFromPackageName(packageName: packageName)
        return FileManager.default.fileExists(atPath: dirPath.path)
    }
    
    func scriptCount() -> Int {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: self.scriptDirectory.path) else { return 0 }
        var count = 0;
        for (_, packageName) in items.enumerated() {
            let packagePath = self.getPackagePathFromPackageName(packageName: packageName)
            if packagePath.isDirectory {
                count += 1
            }
        }
        return count
    }
    
    func listScripts() -> [ScriptModel] {
        return ScriptManager.listScriptsInDirectory(dirPath: self.scriptDirectory, readonly: false)
    }
    
    func asyncListScripts() async -> [ScriptModel] {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let models = self.listScripts()
                continuation.resume(returning: models)
            }
        }
    }
    
    
    static func listBundleScripts(bundle: String, relativePath: String) -> [ScriptModel] {
        guard let bundleURL = Bundle.main.url(forResource: bundle, withExtension: "bundle") else { return [] }
        let dirPath = bundleURL.appendingPathComponent(relativePath)
        
        return ScriptManager.listScriptsInDirectory(dirPath: dirPath, readonly: true)
    }
    
    
    static func listScriptsInDirectory(dirPath: URL, readonly: Bool) -> [ScriptModel] {
        var models = [ScriptModel]()
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dirPath.path) else { return [] }
        for (_, packageName) in items.enumerated() {
            let packagePath = dirPath.appendingPathComponent(packageName)
            // we only care about directory, ignore file
            if !packagePath.isDirectory {
                continue
            }
            models.append(ScriptModel(package: ScriptWidgetPackage(path: packagePath, readonly: readonly)))
        }
        models.sort { (a, b) -> Bool in
            return a.name < b.name
        }
        return models
    }
    
    func getScriptPackage(packageName: String) -> ScriptWidgetPackage {
        let scriptDirPath = self.getPackagePathFromPackageName(packageName: packageName)
        return ScriptWidgetPackage(path: scriptDirPath)
    }
    
    func deleteScript(packageName: String) -> Bool {
        let scriptDirPath = self.getPackagePathFromPackageName(packageName: packageName)
        let package = ScriptWidgetPackage(path: scriptDirPath)
        let deleteResult = package.delete()
        
        let deleteBuildResult = removeBuildScriptPackage(package: package)
        
        return deleteResult && deleteBuildResult.0
    }
    
    static func readBundleFile(bundle: String, fileName: String) ->  String? {
        guard let bundleUrl = Bundle.main.url(forResource: bundle, withExtension: "bundle") else {
            return nil
        }
        let filePath = bundleUrl.appendingPathComponent(fileName);
        guard let content = try? String(contentsOf: filePath, encoding: .utf8) else {
            return nil
        }
        return content
    }
}

// icloud update
extension ScriptManager {
    
    func requestUpdateICloudScripts() {
        let models = self.listScripts()
        for model in models {
            model.package.updateFiles()
        }
    }
}

// export and import
extension ScriptManager {
    
    func exportScript(model: ScriptModel, toPath: URL) -> Bool {
        guard model.package.ensureManifest().0 else { return false }
        let validation = WidgetPackageManifestValidator.validate(model.package.effectiveManifest(), package: model.package)
        guard validation.isValid else { return false }
        let packageDir = model.package.path
        let result = SSZipArchive.createZipFile(atPath: toPath.path, withContentsOfDirectory: packageDir.path, keepParentDirectory: true)
        return result
    }
    
    func exportScriptItemsInTempPath(model: ScriptModel) -> [URL] {

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let tempFilePath = tempDir.appendingPathComponent(model.exportFileName)

        // remove if existed
        if FileManager.default.fileExists(atPath: tempFilePath.path) {
            try? FileManager.default.removeItem(at: tempFilePath)
        }

        // create new file
        let result = exportScript(model: model, toPath: tempFilePath)
        if !result {
            return []
        }
        
        return [tempFilePath]
    }
    
    func importScript(fromPath: URL) -> Bool {
        importScriptPackage(fromPath: fromPath).succeeded
    }

    func importScriptPackage(fromPath: URL) -> ScriptPackageImportResult {
        if let preflightError = ScriptPackageArchivePreflight.validate(fromPath) {
            return .init(succeeded: false, packageName: nil, message: preflightError, validation: nil)
        }
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptWidgetImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempPath) }
        do {
            try FileManager.default.createDirectory(at: tempPath, withIntermediateDirectories: true)
        } catch {
            return .init(succeeded: false, packageName: nil, message: error.localizedDescription, validation: nil)
        }
        guard SSZipArchive.unzipFile(atPath: fromPath.path, toDestination: tempPath.path) else {
            return .init(succeeded: false, packageName: nil, message: "The package could not be extracted.", validation: nil)
        }
        guard let extractedPackage = extractedPackageRoot(in: tempPath) else {
            return .init(succeeded: false, packageName: nil, message: "The archive must contain one widget package.", validation: nil)
        }
        if let extractedError = validateExtractedTree(extractedPackage) {
            return .init(succeeded: false, packageName: nil, message: extractedError, validation: nil)
        }

        let temporaryPackage = ScriptWidgetPackage(path: extractedPackage)
        if temporaryPackage.readManifest() == nil {
            let migration = temporaryPackage.writeManifest(.legacy(
                name: extractedPackage.lastPathComponent,
                metadata: temporaryPackage.readMetadata()
            ))
            guard migration.0 else {
                return .init(succeeded: false, packageName: nil, message: migration.1, validation: nil)
            }
        }
        guard let manifest = temporaryPackage.readManifest() else {
            return .init(succeeded: false, packageName: nil, message: "widget.json is invalid.", validation: nil)
        }
        let report = WidgetPackageManifestValidator.validate(manifest, package: temporaryPackage)
        guard report.isValid else {
            return .init(
                succeeded: false,
                packageName: nil,
                message: report.errors.map(\.message).joined(separator: "\n"),
                validation: report
            )
        }

        let importedName = getValidPackageName(recommendPackageName: manifest.name)
        let destination = getPackagePathFromPackageName(packageName: importedName)
        do {
            try FileManager.default.copyItem(at: extractedPackage, to: destination)
        } catch {
            return .init(succeeded: false, packageName: nil, message: error.localizedDescription, validation: report)
        }
        if !isBuild {
            _ = buildScriptPackage(package: getScriptPackage(packageName: importedName))
        }
        return .init(succeeded: true, packageName: importedName, message: "", validation: report)
    }

    private func extractedPackageRoot(in directory: URL) -> URL? {
        let children = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.lastPathComponent != "__MACOSX" }
        if children.contains(where: { $0.lastPathComponent == "main.jsx" || $0.lastPathComponent == "widget.json" }) {
            return directory
        }
        let directories = children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        guard directories.count == 1 else { return nil }
        return directories[0]
    }

    private func validateExtractedTree(_ root: URL) -> String? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return "Extracted package could not be enumerated." }
        var count = 0
        var total = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isSymbolicLink == true { return "Symbolic links are not allowed." }
            guard values?.isRegularFile == true else { continue }
            count += 1
            guard let size = values?.fileSize, size >= 0 else { return "Package file size could not be verified." }
            if count > ScriptPackageArchivePolicy.maximumFileCount { return "Package contains too many files." }
            if size > ScriptPackageArchivePolicy.maximumFileBytes { return "Package file \(url.lastPathComponent) exceeds 25 MiB." }
            guard total <= ScriptPackageArchivePolicy.maximumExpandedBytes - size else {
                return "Expanded package exceeds 64 MiB."
            }
            total += size
            if total > ScriptPackageArchivePolicy.maximumExpandedBytes { return "Expanded package exceeds 64 MiB." }
        }
        return nil
    }
    
}


extension ScriptManager {
    
    
    func buildScriptPackage(package: ScriptWidgetPackage) -> (Bool, String) {
        if isBuild {
            return (false, "Not work when is build is true")
        }
        guard let buildDirectory = Self.getSandboxBuildDirectoryURL() else {
            return (false, "Failed to get build directory")
        }
        
        self.makeSureDirectoryExist(path: buildDirectory)
        
        // remove target
        let targetDirectory = buildDirectory.appendingPathComponent(package.name)
        
        if FileManager.default.fileExists(atPath: targetDirectory.path) {
            do {
                try FileManager.default.removeItem(at: targetDirectory)
            } catch {
                return (false, "Failed to remove old files : \(error)")
            }
        }
        
        // copy new to target
        do {
            try FileManager.default.copyItem(at: package.path, to: targetDirectory)
        } catch {
            return (false, "Failed to copy files : \(error)")
        }
        
        return (true, "Succeed")
    }
    
    func removeBuildScriptPackage(package: ScriptWidgetPackage) -> (Bool, String) {
        if isBuild {
            return (false, "Not work when is build is true")
        }
        guard let buildDirectory = Self.getSandboxBuildDirectoryURL() else {
            return (false, "Failed to get build directory")
        }
        
        self.makeSureDirectoryExist(path: buildDirectory)
        
        // remove target
        let targetDirectory = buildDirectory.appendingPathComponent(package.name)
        
        if !FileManager.default.fileExists(atPath: targetDirectory.path) {
            return (true, "Already removed")
        }
        
        do {
            try FileManager.default.removeItem(at: targetDirectory)
        } catch {
            return (false, "Failed to remove old files : \(error)")
        }
        
        return (true, "Succeed")
    }

    func buildAllScriptPackages() -> (Bool, String) {
        if isBuild {
            return (false, "Not work when is build is true")
        }
        
        let items = listScripts()
        for item in items {
            _ = buildScriptPackage(package: item.package)
        }
        
        return (true, "Succeed")
    }
    
    func removeAllBuildScriptPackages() -> (Bool, String) {

        if isBuild {
            return (false, "Not work when is build is true")
        }

        let items = listScripts()
        for item in items {
            _ = removeBuildScriptPackage(package: item.package)
        }

        return (true, "Succeed")
    }


}

// MARK: - Proactive local caching (issue #6)
//
// When iCloud Drive is unavailable (e.g. cellular with iCloud disabled, or the
// system evicting unused ubiquitous files), reading a script's files fails and
// the widget shows an error. `ScriptWidgetPackage.readFile` already falls back
// to a per-file build cache, but that cache is only populated when a file has
// been successfully read at least once on this device — so a script synced from
// another device that was never opened here had nothing to fall back to.
//
// These helpers proactively cache every script's runtime files and bounded
// image resources while iCloud is reachable, so later eviction still renders
// the complete widget from the cache.
extension ScriptManager {

    /// Text is required to execute the widget; common image formats are also
    /// retained so an offline fallback does not render an incomplete layout.
    private static let textCacheableExtensions: Set<String> = ["jsx", "js", "json", "txt", "csv", "svg", "md"]
    private static let binaryCacheableExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]
    private static let maximumCachedResourceBytes = 25 * 1024 * 1024

    /// How long a single precache pass will wait for one evicted iCloud file to
    /// download before moving on. Bounded so a slow/absent network can't stall
    /// the whole pass; remaining files are simply picked up on the next pass.
    private static let precacheDownloadTimeout: TimeInterval = 8

    /// Read and locally cache one package's runtime files. A successful read writes
    /// the per-file build cache that `readFile` falls back to. For files that
    /// iCloud has evicted this requests the download and *waits* (bounded) for it
    /// to materialize before reading — so an evicted file is cached on this pass
    /// rather than only after a later app launch (issue #6). MUST be called off
    /// the main thread. Returns the number of files cached this pass.
    @discardableResult
    func precachePackageFiles(_ package: ScriptWidgetPackage) -> Int {
        if isBuild { return 0 }
        var cached = 0
        for fileURL in cacheableFileURLs(in: package.path) {
            guard ensureDownloaded(fileURL) else { continue }
            let pathExtension = fileURL.pathExtension.lowercased()
            if Self.textCacheableExtensions.contains(pathExtension),
               package.readFile(fullPath: fileURL).0 != nil {
                cached += 1
            } else if Self.binaryCacheableExtensions.contains(pathExtension),
                      resourceSize(fileURL) <= Self.maximumCachedResourceBytes,
                      package.cacheResource(fullPath: fileURL) {
                cached += 1
            }
        }
        return cached
    }

    /// Proactively cache every script so widgets keep rendering when iCloud is
    /// later unavailable. Call when the app becomes active / is online.
    func precacheAllScripts() {
        if isBuild { return }
        for model in listScripts() {
            precachePackageFiles(model.package)
        }
    }

    /// Logical URLs of cacheable runtime files under `root`, resolving iCloud
    /// placeholders (".main.jsx.icloud") back to their real names so evicted
    /// files are still discovered and downloaded.
    private func cacheableFileURLs(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                continue
            }
            let logical = Self.logicalURL(for: url)
            let pathExtension = logical.pathExtension.lowercased()
            if Self.textCacheableExtensions.contains(pathExtension)
                || Self.binaryCacheableExtensions.contains(pathExtension) {
                result.append(logical)
            }
        }
        return result
    }

    private func resourceSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
    }

    /// Map an iCloud placeholder URL (".main.jsx.icloud") back to its logical
    /// file URL ("main.jsx"); returns `url` unchanged for normal files.
    static func logicalURL(for url: URL) -> URL {
        let name = url.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return url }
        let logicalName = String(name.dropFirst().dropLast(".icloud".count))
        return url.deletingLastPathComponent().appendingPathComponent(logicalName)
    }

    /// Ensure a (possibly iCloud-evicted) file is present locally. Returns
    /// immediately if it already exists; otherwise requests the download and
    /// polls up to `precacheDownloadTimeout`. Returns whether the file is present
    /// afterwards. MUST be called off the main thread.
    private func ensureDownloaded(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        let deadline = Date().addingTimeInterval(Self.precacheDownloadTimeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey]),
               let error = values.ubiquitousItemDownloadingError {
                print("precache: iCloud download error for \(url.lastPathComponent): \(error)")
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
}






let sharedScriptManager = ScriptManager(isBuild: false)
let buildScriptManager = ScriptManager(isBuild: true)



extension URL {
    var isDirectory: Bool {
       (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
