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



class ScriptManager {
    
    let scriptDirectory: URL
    let isUsingiCloud: Bool
    let isBuild: Bool
    
    init(isBuild: Bool) {
        self.isBuild = isBuild
        if isBuild {
            self.scriptDirectory = Self.getSandboxBuildDirectoryURL()!
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
        } else {
            root = ScriptManager.getSandboxRootDirectoryURL()!
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
            return url.appendingPathComponent("__Build")
        }
        return nil
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
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let tempPath = tempDir.appendingPathComponent("ScriptWidgetTempImport")
        
        try? FileManager.default.createDirectory(at: tempPath, withIntermediateDirectories: true, attributes: [
            FileAttributeKey.protectionKey : FileProtectionType.none
        ])
        
        print("temp path : \(tempPath)")
        
        let result = SSZipArchive.unzipFile(atPath: fromPath.path, toDestination: tempPath.path)
        if !result {
            return false
        }
        
        let originalImportScriptName = fromPath.deletingPathExtension().lastPathComponent
        let tempPackagePath = tempPath.appendingPathComponent(originalImportScriptName)
        print("target package path : \(tempPackagePath)")
        
        // copy
        let confirmImportScriptName = self.getValidPackageName(recommendPackageName: originalImportScriptName)
        let confirmPackagePath = self.getPackagePathFromPackageName(packageName: confirmImportScriptName)
        print("target path : \(confirmPackagePath)")
        
        do {
            try FileManager.default.moveItem(at: tempPackagePath, to: confirmPackagePath)
        } catch {
            return false
        }
        
        if !self.isBuild {
            let package = self.getScriptPackage(packageName: confirmImportScriptName)
            _ = buildScriptPackage(package: package)
        }
        return true
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






let sharedScriptManager = ScriptManager(isBuild: false)
let buildScriptManager = ScriptManager(isBuild: true)



extension URL {
    var isDirectory: Bool {
       (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
