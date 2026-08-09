//
//  ImportExportManager.swift
//  ScriptWidget
//
//  Created by eevv on 11/5/24.
//
//

import Foundation
import ZipArchive

class ExportManager {
    static func exportAllScripts(progressCallback: @escaping (Float, String) -> Void) async throws -> URL {
        // Create a temporary directory for exporting scripts
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("scriptwidget-export-all")
        let zipFilePath = FileManager.default.temporaryDirectory.appendingPathComponent("scriptwidget-export-all.zip")
        
        // Remove existing temp directory and zip file if they exist
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: zipFilePath)
        
        // Create the temporary directory
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        
        // List all scripts
        let scripts = await sharedScriptManager.asyncListScripts()
        let totalScripts = Float(scripts.count)
        
        // Export each script to the temporary directory
        for (index, script) in scripts.enumerated() {
            let scriptPath = tempDir.appendingPathComponent(script.name)
            _ = sharedScriptManager.exportScript(model: script, toPath: scriptPath)
            
            // Update progress with script name
            let progress = Float(index + 1) / totalScripts
            await MainActor.run {
                progressCallback(progress * 0.9, "Exporting: \(script.name)") // 90% of progress for exporting scripts
            }
        }
        
        // Create zip file from the temporary directory
        await MainActor.run {
            progressCallback(0.95, "Creating zip file") // 95% progress when starting zip creation
        }
        let success = SSZipArchive.createZipFile(atPath: zipFilePath.path, withContentsOfDirectory: tempDir.path)
        
        if success {
            // Remove the temporary directory
            try? FileManager.default.removeItem(at: tempDir)
            
            // Final progress update
            await MainActor.run {
                progressCallback(1.0, "Export completed")
            }
            
            return zipFilePath
        } else {
            throw NSError(domain: "ExportManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create zip file"])
        }
    }
}

class ImportManager {
    static func importScripts(from fileURL: URL, progressCallback: @escaping (Float, String) -> Void) async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("scriptwidget-import")
        
        // Remove existing temp directory if it exists
        try? FileManager.default.removeItem(at: tempDir)
        
        // Create the temporary directory
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        
        // Extract zip file
        await MainActor.run {
            progressCallback(0.1, "Extracting zip file")
        }
        
        // Start accessing the security-scoped resource
        guard fileURL.startAccessingSecurityScopedResource() else {
            throw NSError(domain: "ImportManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to access the selected file"])
        }
        
        // Ensure we stop accessing the resource when we're done
        defer {
            fileURL.stopAccessingSecurityScopedResource()
        }
        
        // Copy the file to a temporary location
        let tempZipPath = tempDir.appendingPathComponent("temp.zip")
        try FileManager.default.copyItem(at: fileURL, to: tempZipPath)
        
        guard SSZipArchive.unzipFile(atPath: tempZipPath.path, toDestination: tempDir.path) else {
            throw NSError(domain: "ImportManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to extract zip file"])
        }
        
        // Remove the temporary zip file
        try? FileManager.default.removeItem(at: tempZipPath)
        
        // The rest of your code remains the same
        
        // Get all files in the extracted directory
        let fileManager = FileManager.default
        let files = try fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        let totalFiles = Float(files.count)
        
        // Import each script
        for (index, file) in files.enumerated() {
            let fileName = file.lastPathComponent
            await MainActor.run {
                progressCallback(0.2 + 0.7 * (Float(index) / totalFiles), "Importing: \(fileName)")
            }
            
            // Import the script using your ScriptManager
            let success = sharedScriptManager.importScript(fromPath: file)
            if !success {
                print("Failed to import script: \(fileName)")
            }
        }
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
        
        await MainActor.run {
            progressCallback(1.0, "Import completed")
        }
    }
}
