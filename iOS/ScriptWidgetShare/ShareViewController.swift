//
//  ShareViewController.swift
//  ScriptWidgetShare
//
//  Created by everettjf on 2021/3/16.
//

import UIKit
import UniformTypeIdentifiers


class ShareViewController: UIViewController {
    private let typeURL = UTType.url.identifier
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        processShareInfo()
    }
    
    private func processShareInfo() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let itemProvider = extensionItem.attachments?.first else {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }
        
        if !itemProvider.hasItemConformingToTypeIdentifier(typeURL) {
            print("Error: No url or text found")
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }
        
        itemProvider.loadItem(forTypeIdentifier: typeURL, options: nil) { (item, error) in
            if let error = error {
                print("URL-Error: \(error.localizedDescription)")
            }

            if let url = item as? NSURL {
                self.importFileWithURL(fileURL: url as URL)
            }

            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
    
    
    private func importFileWithURL(fileURL: URL) {
        print(fileURL)
        
        let fileExt = fileURL.pathExtension.lowercased()
        switch fileExt {
        case "jsx": importJSXFile(fileURL: fileURL)
        case "swt": importSWTFile(fileURL: fileURL)
        default: print("un support file format")
        }
    }
    
    private func importSWTFile(fileURL: URL) {
        
        let result = sharedScriptManager.importScript(fromPath: fileURL)
        if result {
            print("import swt succeed")
            
            self.openAppAfterImported()

        } else {
            print("import swt failed")
        }
    }
    
    private func importJSXFile(fileURL: URL) {
        let fileName = fileURL.lastPathComponent
        let fileNameWithoutExt = fileURL.deletingPathExtension().lastPathComponent
        
        print("fileName = \(fileName)")
        print("fileNameWithoutExt = \(fileNameWithoutExt)")

        // save to icloud or sandbox
        let targetPackageName = fileNameWithoutExt
        
        do {
            let fileContent = try String(contentsOf: fileURL, encoding: .utf8)
            
            let result = sharedScriptManager.createScript(content: fileContent, recommendPackageName: targetPackageName, imageCopyPath: nil)
            if result.0 {
                print("succeed import")
                
                self.openAppAfterImported()

            } else {
                print("save script failed : \(result.1)")
            }
        
        } catch {
            print("read file failed : \(error)")
        }
    }
    
    private func openAppAfterImported() {
        
        if let appurl = URL(string: "scriptwidget://") {
            self.openURL(appurl)
        }
    }
    
    //  Function must be named exactly like this so a selector can be found by the compiler!
    //  Anyway - it's another selector in another instance that would be "performed" instead.
    @discardableResult
    @objc func openURL(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                return application.perform(#selector(openURL(_:)), with: url) != nil
            }
            responder = responder?.next
        }
        return false
    }
}
